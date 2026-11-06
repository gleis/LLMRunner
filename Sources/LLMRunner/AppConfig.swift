import Foundation

struct AppConfig: Codable, Sendable {
    struct Server: Codable, Sendable {
        var host: String
        var port: UInt16
    }

    struct Backend: Codable, Sendable {
        var mode: String?
        var executable: String
        var host: String
        var port: UInt16
        var extraArguments: [String]
        var startupTimeoutSeconds: TimeInterval
    }

    struct Model: Codable, Sendable {
        var id: String
        var path: String
        var contextSize: Int?
        var gpuLayers: Int?
        var arguments: [String]
    }

    struct Security: Codable, Sendable {
        var apiKeys: [String]
        var apiKeyEnv: String?
        var maxRequestBodyBytes: Int?
        /// Optional endpoint paths per key. Unlisted keys keep full API access.
        var keyScopes: [String: [String]]? = nil
        var requestsPerMinute: Int? = nil
    }

    struct Logging: Codable, Sendable {
        var requests: Bool
        var level: String
    }

    var server: Server
    var backend: Backend
    var security: Security?
    var logging: Logging?
    var defaultModel: String
    var models: [Model]

    static let defaultPath = RuntimePaths.directory.appendingPathComponent("config.json")

    static func loadOrCreate(arguments: [String]) throws -> AppConfig {
        let path = configPath(from: arguments)
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            let config = AppConfig.defaultConfig()
            try config.save(to: url)
            return config
        }

        return try load(arguments: arguments)
    }

    static func load(arguments: [String]) throws -> AppConfig {
        let path = configPath(from: arguments)
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.missingConfig(path: url.path)
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(AppConfig.self, from: data)
    }

    static func resolvedConfigURL(arguments: [String]) -> URL {
        URL(fileURLWithPath: configPath(from: arguments))
    }

    static func defaultConfig() -> AppConfig {
        AppConfig(
            server: Server(host: "127.0.0.1", port: 8080),
            backend: Backend(
                mode: "embedded",
                executable: "llama-server",
                host: "127.0.0.1",
                port: 8081,
                extraArguments: ["--jinja"],
                startupTimeoutSeconds: 60
            ),
            security: Security(
                apiKeys: [],
                apiKeyEnv: "LLMRUNNER_API_KEY",
                maxRequestBodyBytes: 10_485_760
            ),
            logging: Logging(
                requests: true,
                level: "info"
            ),
            defaultModel: "",
            models: []
        )
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }

    func model(id: String?) -> Model? {
        if let id, let requested = models.first(where: { $0.id == id }) {
            return requested
        }

        if let defaultConfigured = models.first(where: { $0.id == defaultModel }) {
            return defaultConfigured
        }

        return models.first
    }

    var usesEmbeddedBackend: Bool {
        backend.mode?.lowercased() != "server"
    }

    var effectiveSecurity: Security {
        security ?? Security(apiKeys: [], apiKeyEnv: "LLMRUNNER_API_KEY", maxRequestBodyBytes: 10_485_760)
    }

    func configuredAPIKeys(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let security = effectiveSecurity
        var keys = security.apiKeys
        if let name = security.apiKeyEnv?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty, let key = environment[name] { keys.append(key) }
        return keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1"].contains(server.host.lowercased())
    }

    func validateSecurity(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if !isLoopback && configuredAPIKeys(environment: environment).isEmpty {
            throw SecurityError.keyRequired
        }
        if !usesEmbeddedBackend {
            let hosts = ["127.0.0.1", "localhost", "::1"]
            let extra = backend.extraArguments + models.flatMap { $0.arguments }
            if !hosts.contains(backend.host.lowercased()) || extra.contains(where: { $0 == "--host" || $0.hasPrefix("--host=") }) {
                throw SecurityError.backendMustBeLocal
            }
        }
        if let scopes = effectiveSecurity.keyScopes {
            let configured = Set(configuredAPIKeys(environment: environment))
            for key in scopes.keys {
                if key.isEmpty || key != key.trimmingCharacters(in: .whitespacesAndNewlines) || !configured.contains(key) {
                    throw SecurityError.invalidScopeKey
                }
            }
        }
        if let limit = effectiveSecurity.requestsPerMinute, limit <= 0 {
            throw SecurityError.invalidRateLimit
        }
    }

    var effectiveLogging: Logging {
        logging ?? Logging(requests: true, level: "info")
    }

    private static func configPath(from arguments: [String]) -> String {
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--config":
                if let value = iterator.next() {
                    return NSString(string: value).expandingTildeInPath
                }
            case let value where value.hasPrefix("--config="):
                let raw = String(value.dropFirst("--config=".count))
                return NSString(string: raw).expandingTildeInPath
            default:
                continue
            }
        }

        return defaultPath.path
    }
}

enum ConfigError: LocalizedError {
    case missingConfig(path: String)

    var errorDescription: String? {
        switch self {
        case .missingConfig(let path):
            return "Missing config at \(path). Create one from config.example.json or pass --config /path/to/config.json."
        }
    }
}

enum SecurityError: LocalizedError {
    case keyRequired, invalidRateLimit, backendMustBeLocal, invalidScopeKey
    var errorDescription: String? {
        switch self {
        case .keyRequired: "An API key is required when binding outside localhost. Configure security.apiKeys or LLMRUNNER_API_KEY."
        case .backendMustBeLocal: "The managed llama-server backend must bind to loopback; --host overrides are not allowed."
        case .invalidScopeKey: "security.keyScopes keys must exactly match configured, trimmed API keys."
        case .invalidRateLimit: "security.requestsPerMinute must be greater than zero."
        }
    }
}
