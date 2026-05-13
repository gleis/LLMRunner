import Foundation

enum AppLogger {
    static func info(_ message: String) {
        write(level: "info", message: message)
    }

    static func warning(_ message: String) {
        write(level: "warn", message: message)
    }

    static func error(_ message: String) {
        write(level: "error", message: message)
    }

    static func request(_ request: HTTPRequest, statusCode: Int, duration: TimeInterval) {
        let durationMS = Int((duration * 1000).rounded())
        write(
            level: "request",
            message: "\(request.method) \(request.querylessPath) -> \(statusCode) \(durationMS)ms"
        )
    }

    private static func write(level: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardOutput.write(Data("\(timestamp) [\(level)] \(message)\n".utf8))
    }
}
