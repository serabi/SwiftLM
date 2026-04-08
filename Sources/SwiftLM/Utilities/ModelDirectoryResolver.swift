import Foundation

/// Resolve a model ID to its local directory (if already downloaded).
/// Checks: 1) local path, 2) HuggingFace Hub cache.
/// Returns nil if the model hasn't been downloaded yet.
func resolveModelDirectory(modelId: String) -> URL? {
    let fm = FileManager.default

    // Direct local path
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: modelId, isDirectory: &isDir), isDir.boolValue {
        let url = URL(filePath: modelId)
        // Verify config.json exists
        if fm.fileExists(atPath: url.appendingPathComponent("config.json").path) {
            return url
        }
    }

    // HuggingFace Hub cache: ~/Library/Caches/huggingface/hub/models--{org}--{model}/snapshots/{hash}/
    // Also check: ~/.cache/huggingface/hub/models--{org}--{model}/snapshots/{hash}/
    let hubModelDir = modelId.replacingOccurrences(of: "/", with: "--")

    let cacheDirs: [URL] = [
        // macOS standard: ~/Library/Caches/huggingface
        fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface/hub/models--\(hubModelDir)"),
        // Unix standard: ~/.cache/huggingface
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(hubModelDir)")
    ].compactMap { $0 }

    for cacheDir in cacheDirs {
        let snapshotsDir = cacheDir.appendingPathComponent("snapshots")
        guard let snapshots = try? fm.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            continue
        }
        // Use the most recently modified snapshot
        let sorted = snapshots
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { a, b in
                let aDate = (try? fm.attributesOfItem(atPath: a.path)[.modificationDate] as? Date) ?? .distantPast
                let bDate = (try? fm.attributesOfItem(atPath: b.path)[.modificationDate] as? Date) ?? .distantPast
                return aDate > bDate
            }
        if let latest = sorted.first {
            if fm.fileExists(atPath: latest.appendingPathComponent("config.json").path) {
                return latest
            }
        }
    }

    return nil
}
