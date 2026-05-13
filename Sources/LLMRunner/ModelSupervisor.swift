import Foundation

actor ModelSupervisor {
    private let config: AppConfig
    private var activeModelID: String?
    private var process: Process?

    init(config: AppConfig) {
        self.config = config
    }

    func ensureRunning(model: AppConfig.Model) async throws {
        if activeModelID == model.id, let process, process.isRunning {
            return
        }

        stopCurrent()

        let process = Process()
        process.executableURL = try BackendExecutableResolver.resolve(config.backend.executable)
        process.arguments = arguments(for: model)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()

        self.process = process
        self.activeModelID = model.id

        try await waitForBackend()
    }

    func stopCurrent() {
        guard let process, process.isRunning else {
            return
        }

        process.terminate()
        self.process = nil
        self.activeModelID = nil
    }

    private func arguments(for model: AppConfig.Model) -> [String] {
        var arguments = [
            "--model", NSString(string: model.path).expandingTildeInPath,
            "--host", config.backend.host,
            "--port", "\(config.backend.port)"
        ]

        if let contextSize = model.contextSize {
            arguments.append(contentsOf: ["--ctx-size", "\(contextSize)"])
        }

        if let gpuLayers = model.gpuLayers {
            arguments.append(contentsOf: ["--n-gpu-layers", "\(gpuLayers)"])
        }

        arguments.append(contentsOf: config.backend.extraArguments)
        arguments.append(contentsOf: model.arguments)
        return arguments
    }

    private func waitForBackend() async throws {
        let deadline = Date().addingTimeInterval(config.backend.startupTimeoutSeconds)
        let url = URL(string: "http://\(config.backend.host):\(config.backend.port)/health")!

        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, (200..<500).contains(httpResponse.statusCode) {
                    return
                }
            } catch {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
        }

        throw BackendError.startupTimedOut
    }
}

enum BackendError: LocalizedError {
    case startupTimedOut
    case missingModel
    case missingExecutable(configuredValue: String, searched: [String])

    var errorDescription: String? {
        switch self {
        case .startupTimedOut:
            return "The model backend did not become ready before the startup timeout."
        case .missingModel:
            return "No model is configured for this request."
        case .missingExecutable(let configuredValue, let searched):
            return "Could not find executable '\(configuredValue)'. Searched: \(searched.joined(separator: ", "))"
        }
    }
}
