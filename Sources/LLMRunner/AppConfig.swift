import Foundation

struct AppConfig: Codable, Sendable {
    struct Server: Codable, Sendable {
        var host: String
        var port: UInt16
    }

    struct Backend: Codable, Sendable {
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

    var server: Server
    var backend: Backend
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
                executable: "llama-server",
                host: "127.0.0.1",
                port: 8081,
                extraArguments: ["--jinja"],
                startupTimeoutSeconds: 60
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
