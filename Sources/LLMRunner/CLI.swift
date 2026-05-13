import Darwin
import Foundation

enum CLI {
    static func run(arguments: [String]) async throws {
        let command = arguments.dropFirst().first ?? "serve"

        switch command {
        case "serve":
            try await serve(arguments: normalizedServeArguments(arguments))
        case "start":
            try start(arguments: arguments)
        case "stop":
            try stop()
        case "status":
            try await status(arguments: arguments)
        case "logs":
            try await logs(arguments: arguments)
        case "models":
            try await ModelsCLI.run(arguments: arguments)
        case "help", "--help", "-h":
            printHelp()
        default:
            if command.hasPrefix("-") {
                try await serve(arguments: arguments)
            } else {
                throw CLIError.unknownCommand(command)
            }
        }
    }

    private static func normalizedServeArguments(_ arguments: [String]) -> [String] {
        guard arguments.dropFirst().first == "serve" else {
            return arguments
        }

        var normalized = [arguments[0]]
        normalized.append(contentsOf: arguments.dropFirst(2))
        return normalized
    }

    private static func serve(arguments: [String]) async throws {
        try RuntimePaths.ensureRuntimeDirectory()
        try writePID(getpid())

        let config = try AppConfig.loadOrCreate(arguments: arguments)
        logStartupSecurityState(config)
        let supervisor = ModelSupervisor(config: config)
        let embeddedBackend = EmbeddedLlamaBackend()
        let service = OpenAIService(config: config, supervisor: supervisor, embeddedBackend: embeddedBackend)
        let server = HTTPServer(
            host: config.server.host,
            port: config.server.port,
            requestLogging: config.effectiveLogging.requests,
            maxRequestBodyBytes: config.effectiveSecurity.maxRequestBodyBytes ?? 10_485_760
        ) { request in
            await service.handle(request)
        }

        try await server.start()
    }

    private static func start(arguments: [String]) throws {
        try RuntimePaths.ensureRuntimeDirectory()

        if let pid = try readPID(), processIsRunning(pid: pid) {
            print("LLMRunner is already running with pid \(pid).")
            return
        }

        let configURL = AppConfig.resolvedConfigURL(arguments: arguments)
        if !FileManager.default.fileExists(atPath: configURL.path) {
            let config = AppConfig.defaultConfig()
            try config.save(to: configURL)
            print("Created default config at \(configURL.path)")
        }

        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--config", configURL.path]
        process.standardOutput = try appendHandle(for: RuntimePaths.logFile)
        process.standardError = try appendHandle(for: RuntimePaths.errorLogFile)

        try process.run()
        try writePID(process.processIdentifier)
        print("Started LLMRunner with pid \(process.processIdentifier).")
        print("Logs: \(RuntimePaths.logFile.path)")
        print("Errors: \(RuntimePaths.errorLogFile.path)")
    }

    private static func stop() throws {
        guard let pid = try readPID() else {
            print("LLMRunner is not running.")
            return
        }

        guard processIsRunning(pid: pid) else {
            try? FileManager.default.removeItem(at: RuntimePaths.pidFile)
            print("LLMRunner is not running.")
            return
        }

        if kill(pid, SIGTERM) == 0 {
            try? FileManager.default.removeItem(at: RuntimePaths.pidFile)
            print("Stopped LLMRunner pid \(pid).")
        } else {
            throw CLIError.processSignalFailed(pid)
        }
    }

    private static func logs(arguments: [String]) async throws {
        let values = Array(arguments.dropFirst())
        let showErrors = values.contains("--errors") || values.contains("--error")
        let follow = values.contains("--follow") || values.contains("-f")
        let lineCount = Int(optionValue("--lines", in: values) ?? "100") ?? 100
        let url = showErrors ? RuntimePaths.errorLogFile : RuntimePaths.logFile

        if !FileManager.default.fileExists(atPath: url.path) {
            print("No log file at \(url.path)")
            return
        }

        printTail(of: url, lines: lineCount)

        if follow {
            try await followLog(url)
        }
    }

    private static func status(arguments: [String]) async throws {
        let pid = try readPID()
        let pidRunning = pid.map(processIsRunning(pid:)) ?? false

        print("Service: \(pidRunning ? "running" : "stopped")")
        if let pid {
            print("PID: \(pid)")
        }

        guard pidRunning else {
            return
        }

        let config = try AppConfig.loadOrCreate(arguments: arguments)
        let url = URL(string: "http://\(config.server.host):\(config.server.port)/health")!

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("API: HTTP \(code)")
            if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                print(body)
            }
        } catch {
            print("API: unreachable (\(error.localizedDescription))")
        }
    }

    static func readPID() throws -> pid_t? {
        guard FileManager.default.fileExists(atPath: RuntimePaths.pidFile.path) else {
            return nil
        }

        let text = try String(contentsOf: RuntimePaths.pidFile, encoding: .utf8)
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func processIsRunning(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    static func writePID(_ pid: pid_t) throws {
        try RuntimePaths.ensureRuntimeDirectory()
        try "\(pid)\n".write(to: RuntimePaths.pidFile, atomically: true, encoding: .utf8)
    }

    private static func appendHandle(for url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private static func printHelp() {
        print("""
        Usage:
          llmrunner serve [--config path]
          llmrunner start [--config path]
          llmrunner stop
          llmrunner status [--config path]
          llmrunner logs [--lines 100] [--follow] [--errors]
          llmrunner models list [--config path]
          llmrunner models search <query> [--limit 10]
          llmrunner models files <huggingface-repo>   # marks the recommended GGUF with *
          llmrunner models pull tiny
          llmrunner models pull <huggingface-repo> [--quant Q4_K_M]
          llmrunner models pull <huggingface-repo> --file model.gguf
          llmrunner models pull <search query> [--quant Q4_K_M]
          llmrunner models pull <id> --url <url> [--config path]
          llmrunner models delete <id> [--config path]
        """)
    }

    private static func optionValue(_ name: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == name, index + 1 < arguments.count {
                return arguments[index + 1]
            }

            if argument.hasPrefix("\(name)=") {
                return String(argument.dropFirst(name.count + 1))
            }
        }

        return nil
    }

    private static func logStartupSecurityState(_ config: AppConfig) {
        let boundLocally = ["127.0.0.1", "localhost", "::1"].contains(config.server.host.lowercased())
        let authEnabled = hasConfiguredAPIKey(config)

        if authEnabled {
            AppLogger.info("API key authentication enabled")
        } else {
            AppLogger.warning("API key authentication disabled")
        }

        if !boundLocally && !authEnabled {
            AppLogger.warning("server host \(config.server.host) is not localhost and no API key is configured")
        }
    }

    private static func hasConfiguredAPIKey(_ config: AppConfig) -> Bool {
        let security = config.effectiveSecurity
        if security.apiKeys.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }

        guard
            let envName = security.apiKeyEnv?.trimmingCharacters(in: .whitespacesAndNewlines),
            !envName.isEmpty,
            let value = ProcessInfo.processInfo.environment[envName]?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        return !value.isEmpty
    }

    private static func printTail(of url: URL, lines: Int) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return
        }

        let output = text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(max(lines, 0))
            .joined(separator: "\n")
        print(output)
    }

    private static func followLog(_ url: URL) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        try handle.seekToEnd()

        while true {
            let data = handle.readDataToEndOfFile()
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                print(text, terminator: "")
            }

            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

enum CLIError: LocalizedError {
    case unknownCommand(String)
    case processSignalFailed(pid_t)
    case missingArgument(String)
    case invalidURL(String)
    case modelNotFound(String)
    case noModelsFound(String)
    case noGGUFFiles(String)
    case huggingFace(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "Unknown command '\(command)'. Run llmrunner help."
        case .processSignalFailed(let pid):
            return "Could not signal process \(pid)."
        case .missingArgument(let argument):
            return "Missing required argument: \(argument)"
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .modelNotFound(let id):
            return "No configured model named '\(id)'."
        case .noModelsFound(let query):
            return "No GGUF model repositories found for '\(query)'. Try llmrunner models search \(query)."
        case .noGGUFFiles(let repoID):
            return "No GGUF files found in \(repoID). Try another repo or run llmrunner models search <query>."
        case .huggingFace(let message):
            return message
        }
    }
}
