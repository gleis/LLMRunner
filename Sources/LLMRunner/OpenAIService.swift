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
            case ("POST", "/v1/completions"):
                if config.usesEmbeddedBackend {
                    return try await embeddedCompletion(request)
                }

                return try await proxy(request)
            case ("POST", "/v1/embeddings"):
                if config.usesEmbeddedBackend {
                    return try await embeddedEmbeddings(request)
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
            guard let model = config.model(id: completionRequest.model) else {
                throw BackendError.missingModel
            }

            return embeddedChatStream(model: model, request: completionRequest)
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

    private func embeddedChatStream(model: AppConfig.Model, request: ChatCompletionRequest) -> HTTPResponse {
        let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let created = Int(Date().timeIntervalSince1970)
        let modelID = model.id
        let backend = embeddedBackend

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Self.sseData(object: [
                "id": id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": modelID,
                "choices": [
                    [
                        "index": 0,
                        "delta": ["role": "assistant"],
                        "finish_reason": NSNull()
                    ] as [String: Any]
                ]
            ]))

            let state = EmbeddedStreamState { token in
                continuation.yield(Self.sseData(object: [
                    "id": id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": modelID,
                    "choices": [
                        [
                            "index": 0,
                            "delta": ["content": token],
                            "finish_reason": NSNull()
                        ] as [String: Any]
                    ]
                ]))
            }

            Task {
                do {
                    try await backend.generateChatStream(model: model, request: request, state: state)
                    continuation.yield(Self.sseData(object: [
                        "id": id,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": modelID,
                        "choices": [
                            [
                                "index": 0,
                                "delta": [:],
                                "finish_reason": "stop"
                            ] as [String: Any]
                        ]
                    ]))
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                } catch {
                    continuation.yield(Self.sseData(object: [
                        "error": [
                            "message": error.localizedDescription,
                            "type": "server_error"
                        ]
                    ]))
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                }
            }
        }

        return .stream(
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache"
            ],
            body: stream
        )
    }

    private func embeddedCompletion(_ request: HTTPRequest) async throws -> HTTPResponse {
        let completionRequest = try CompletionRequest(json: request.jsonObject())

        if completionRequest.stream {
            return .json(
                statusCode: 501,
                object: [
                    "error": [
                        "message": "Streaming is implemented for /v1/chat/completions. Completion streaming is not implemented yet.",
                        "type": "server_error"
                    ]
                ]
            )
        }

        guard let model = config.model(id: completionRequest.model) else {
            throw BackendError.missingModel
        }

        let result = try await embeddedBackend.generateCompletion(model: model, request: completionRequest)

        return .json(object: [
            "id": result.id,
            "object": "text_completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": result.model,
            "choices": [
                [
                    "text": result.text,
                    "index": 0,
                    "logprobs": NSNull(),
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

    private func embeddedEmbeddings(_ request: HTTPRequest) async throws -> HTTPResponse {
        let embeddingRequest = try EmbeddingRequest(json: request.jsonObject())

        guard let model = config.model(id: embeddingRequest.model) else {
            throw BackendError.missingModel
        }

        let data = try await embeddingRequest.inputs.enumerated().asyncMap { index, input in
            let vector = try await embeddedBackend.embed(model: model, input: input)
            return [
                "object": "embedding",
                "index": index,
                "embedding": vector
            ] as [String: Any]
        }

        return .json(object: [
            "object": "list",
            "model": model.id,
            "data": data,
            "usage": [
                "prompt_tokens": NSNull(),
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
            body: data,
            streamBody: nil
        )
    }

    private static func sseData(object: Any) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let text = String(decoding: json, as: UTF8.self)
        return Data("data: \(text)\n\n".utf8)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
