import Foundation

final class ProgressTracker {
    var isDone = false
    var spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    var frameIndex = 0
    let modelId: String
    private var trackingTask: Task<Void, Never>?
    private var lastUpdate: TimeInterval = 0
    private var lastBytes: Int64 = 0
    private var speedStr = "0.0 MB/s"

    init(modelId: String) {
        self.modelId = modelId
    }

    func getDownloadedBytes() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folderName = "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        // Check both possible download locations:
        // 1. SwiftLM uses ~/Library/Application Support/MLX/HuggingFace/ (via HubApi downloadBase)
        // 2. Standard HuggingFace CLI uses ~/.cache/huggingface/hub/
        let appSupportDir = URL.applicationSupportDirectory
            .appendingPathComponent("MLX/HuggingFace/\(folderName)")
        let modelHubDir = home.appendingPathComponent(".cache/huggingface/hub/\(folderName)")
        let downloadDir = home.appendingPathComponent(".cache/huggingface/download")

        func sumDir(_ dir: URL) -> Int64 {
            var total: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let file as URL in enumerator {
                    if let attr = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                       let size = attr.fileSize,
                       attr.isSymbolicLink != true {
                        total += Int64(size)
                    }
                }
            }
            return total
        }

        return sumDir(appSupportDir) + sumDir(modelHubDir) + sumDir(downloadDir)
    }

    func printProgress(_ progress: Progress) {
        if trackingTask == nil {
            lastUpdate = Date().timeIntervalSince1970
            lastBytes = getDownloadedBytes()

            trackingTask = Task {
                while !self.isDone && !Task.isCancelled {
                    let now = Date().timeIntervalSince1970
                    let fraction = progress.fractionCompleted
                    let pct = Int(fraction * 100)

                    let interval = now - self.lastUpdate
                    if interval >= 0.25 {
                        self.frameIndex = (self.frameIndex + 1) % self.spinnerFrames.count

                        let currentBytes = self.getDownloadedBytes()
                        let diff = Double(currentBytes - self.lastBytes)
                        if diff >= 0 {
                            let speedMBps = (diff / interval) / 1_048_576.0
                            self.speedStr = String(format: "%.1f MB/s", speedMBps)
                        } else {
                            // File moved/cleaned up cache, omit negative speed
                        }

                        self.lastBytes = currentBytes
                        self.lastUpdate = now
                    }

                    var completedMB = String(format: "%.1f", Double(self.lastBytes) / 1_048_576)
                    var totalMB = "???"
                    if fraction > 0.001 {
                        let extrapolated = (Double(self.lastBytes) / fraction) / 1_048_576.0
                        totalMB = String(format: "%.1f", extrapolated)
                    } else if fraction == 0.0 {
                         completedMB = "0.0"
                    }

                    let barLength = 20
                    let completedBars = min(barLength, Int(fraction * Double(barLength)))
                    let emptyBars = max(0, barLength - completedBars)

                    var bars = ""
                    if completedBars > 0 {
                        bars += String(repeating: "=", count: completedBars - 1) + ">"
                    }
                    bars += String(repeating: " ", count: emptyBars)

                    let pctStr = String(format: "%3d%%", pct)
                    let spinner = self.spinnerFrames[self.frameIndex]
                    let speedText = "| Speed: \(self.speedStr)"

                    let msg = String(format: "\r[SwiftLM] Download: [%@] %@ %@ (%@ MB / %@ MB) %@", bars, pctStr, spinner, completedMB, totalMB, speedText)

                    print(msg.padding(toLength: 100, withPad: " ", startingAt: 0), terminator: "")
                    fflush(stdout)

                    if fraction >= 1.0 {
                        print("")
                        self.isDone = true
                        break
                    }

                    do {
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    } catch {
                        break
                    }
                }
            }
        }
    }
}
