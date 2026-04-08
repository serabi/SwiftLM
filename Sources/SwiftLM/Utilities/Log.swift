import Logging

enum Log {
    static var logger = Logger(label: "com.swiftlm.server")

    static func bootstrap() {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
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
