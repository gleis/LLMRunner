import Foundation

struct OpenAIService: Sendable {
    private let config: AppConfig
    private let supervisor: ModelSupervisor
    private let embeddedBackend: EmbeddedLlamaBackend

    init(config: AppConfig, supervisor: ModelSupervisor, embeddedBackend: EmbeddedLlamaBackend) {
        self.config = config
        self.supervisor = supervisor
        self.embeddedBackend = embeddedBackend
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            switch (request.method, request.querylessPath) {
            case ("GET", "/health"), ("GET", "/v1/health"):
                return .json(object: ["status": "ok"])
            case ("GET", "/v1/models"):
                return modelsResponse()
            case ("POST", "/v1/chat/completions"):
                if config.usesEmbeddedBackend {
                    return try await embeddedChatCompletion(request)
                }

                return try await proxy(request)
            case ("POST", "/v1/completions"),
                 ("POST", "/v1/embeddings"):
                if config.usesEmbeddedBackend {
                    return .json(
                        statusCode: 501,
                        object: [
                            "error": [
                                "message": "\(request.querylessPath) is not implemented by the embedded backend yet. Set backend.mode to server to proxy this route to llama-server.",
                                "type": "server_error"
                            ]
                        ]
                    )
                }

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

    private func embeddedChatCompletion(_ request: HTTPRequest) async throws -> HTTPResponse {
        let completionRequest = try ChatCompletionRequest(json: request.jsonObject())

        if completionRequest.stream {
            return .json(
                statusCode: 501,
                object: [
                    "error": [
                        "message": "Streaming is not implemented by the embedded backend yet.",
                        "type": "server_error"
                    ]
                ]
            )
        }

        guard let model = config.model(id: completionRequest.model) else {
            throw BackendError.missingModel
        }

        let result = try await embeddedBackend.generateChat(model: model, request: completionRequest)
        let created = Int(Date().timeIntervalSince1970)

        return .json(object: [
            "id": result.id,
            "object": "chat.completion",
            "created": created,
            "model": result.model,
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": result.content
                    ],
                    "finish_reason": "stop"
                ] as [String: Any]
            ],
            "usage": [
                "prompt_tokens": NSNull(),
                "completion_tokens": NSNull(),
                "total_tokens": NSNull()
            ]
        ])
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
