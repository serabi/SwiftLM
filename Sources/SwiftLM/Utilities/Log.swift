import Foundation
import Logging

enum Log {
    static var logger = Logger(label: "com.swiftlm.server")

    private static let logFileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".swiftlm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("server.log")
    }()

    private static let logFileHandle: FileHandle? = {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: logFileURL)
        handle?.seekToEndOfFile()
        return handle
    }()

    static func bootstrap() {
        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                StreamLogHandler.standardOutput(label: label),
                FileLogHandler(label: label, fileHandle: logFileHandle)
            ])
        }
        info("Log file: \(logFileURL.path)")
    }

    static func info(_ message: String) {
        logger.info(Logger.Message(stringLiteral: message))
    }

    static func debug(_ message: String) {
        logger.debug(Logger.Message(stringLiteral: message))
    }

    static func warning(_ message: String) {
        logger.warning(Logger.Message(stringLiteral: message))
    }

    static func error(_ message: String) {
        logger.error(Logger.Message(stringLiteral: message))
    }
}

// MARK: - File Log Handler

struct FileLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug
    let label: String
    private let fileHandle: FileHandle?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(label: String, fileHandle: FileHandle?) {
        self.label = label
        self.fileHandle = fileHandle
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = Self.formatter.string(from: Date())
        let entry = "\(timestamp) \(level) [\(label)] \(message)\n"
        if let data = entry.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }
}
