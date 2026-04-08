import Foundation

final class ProgressTracker {
    var isDone = false
    var spinnerFrames = ["\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}"]
    var frameIndex = 0
    let modelId: String
    private var trackingTask: Task<Void, Never>?
    private var lastUpdate: TimeInterval = 0

    init(modelId: String) {
        self.modelId = modelId
    }

    func printProgress(_ progress: Progress) {
        if trackingTask == nil {
            lastUpdate = Date().timeIntervalSince1970

            trackingTask = Task {
                while !self.isDone && !Task.isCancelled {
                    let now = Date().timeIntervalSince1970
                    let fraction = progress.fractionCompleted
                    let pct = Int(fraction * 100)

                    let interval = now - self.lastUpdate
                    if interval >= 0.25 {
                        self.frameIndex = (self.frameIndex + 1) % self.spinnerFrames.count
                        self.lastUpdate = now
                    }

                    // Read speed directly from HuggingFace Hub's Progress object
                    let speedBytesPerSec = progress.userInfo[.throughputKey] as? Double
                    let speedStr: String
                    if let speed = speedBytesPerSec {
                        speedStr = String(format: "%.1f MB/s", speed / 1_048_576.0)
                    } else {
                        speedStr = "-- MB/s"
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

                    let msg = String(format: "\r[SwiftLM] Download: [%@] %@ %@ | Speed: %@",
                                     bars, pctStr, spinner, speedStr)

                    print(msg.padding(toLength: 80, withPad: " ", startingAt: 0), terminator: "")
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
