import Foundation

enum RuntimePaths {
    static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["LLMRUNNER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".llmrunner", isDirectory: true)
    }()

    static let pidFile = directory.appendingPathComponent("llmrunner.pid")
    static let logFile = directory.appendingPathComponent("llmrunner.log")
    static let errorLogFile = directory.appendingPathComponent("llmrunner.err.log")
    static let modelsDirectory = directory.appendingPathComponent("models", isDirectory: true)

    static func ensureRuntimeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }
}
