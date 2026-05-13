import Foundation

struct OpenAIService: Sendable {
    private let config: AppConfig
    private let supervisor: ModelSupervisor

    init(config: AppConfig, supervisor: ModelSupervisor) {
        self.config = config
        self.supervisor = supervisor
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            switch (request.method, request.querylessPath) {
            case ("GET", "/health"), ("GET", "/v1/health"):
                return .json(object: ["status": "ok"])
            case ("GET", "/v1/models"):
                return modelsResponse()
            case ("POST", "/v1/chat/completions"),
                 ("POST", "/v1/completions"),
                 ("POST", "/v1/embeddings"):
                return try await proxy(request)
            default:
                return .json(
                    statusCode: 404,
                    object: [
                        "error": [
                            "message": "No route for \(request.method) \(request.path)",
                            "type": "invalid_request_error"
                        ]
                    ]
                )
            }
        } catch {
            return .json(
                statusCode: 503,
                object: [
                    "error": [
                        "message": error.localizedDescription,
                        "type": "server_error"
                    ]
                ]
            )
        }
    }

    private func modelsResponse() -> HTTPResponse {
        let models = config.models.map { model in
            [
                "id": model.id,
                "object": "model",
                "created": 0,
                "owned_by": "llmrunner"
            ] as [String: Any]
        }

        return .json(object: [
            "object": "list",
            "data": models
        ])
    }

    private func proxy(_ request: HTTPRequest) async throws -> HTTPResponse {
        let requestedModel = try request.jsonObject()["model"] as? String
        guard let model = config.model(id: requestedModel) else {
            throw BackendError.missingModel
        }

        try await supervisor.ensureRunning(model: model)

        let targetURL = URL(string: "http://\(config.backend.host):\(config.backend.port)\(request.path)")!
        var outbound = URLRequest(url: targetURL)
        outbound.httpMethod = request.method
        outbound.httpBody = request.body
        outbound.timeoutInterval = 600

        for (name, value) in request.headers {
            if ["host", "connection", "content-length"].contains(name.lowercased()) {
                continue
            }
            outbound.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: outbound)
        guard let httpResponse = response as? HTTPURLResponse else {
            return .text(statusCode: 502, "Backend returned a non-HTTP response.")
        }

        var headers: [String: String] = [:]
        for (name, value) in httpResponse.allHeaderFields {
            guard let name = name as? String else {
                continue
            }
            headers[name] = "\(value)"
        }

        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            reason: HTTPStatus.reason(for: httpResponse.statusCode),
            headers: headers,
            body: data
        )
    }
}
