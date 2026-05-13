import EmbeddedLlamaC
import Foundation

actor EmbeddedLlamaBackend {
    private var activeModelID: String?
    private var engine: OpaquePointer?

    func generateChat(model: AppConfig.Model, request: ChatCompletionRequest) throws -> ChatCompletionResult {
        try ensureLoaded(model: model)

        guard let engine else {
            throw EmbeddedLlamaError.notLoaded
        }

        let cMessages = request.messages.map { message in
            llmr_message(
                role: strdup(message.role),
                content: strdup(message.content)
            )
        }

        defer {
            for message in cMessages {
                free(UnsafeMutableRawPointer(mutating: message.role))
                free(UnsafeMutableRawPointer(mutating: message.content))
            }
        }

        let options = llmr_generation_options(
            max_tokens: Int32(request.maxTokens ?? 256),
            temperature: Float(request.temperature ?? 0.2),
            top_k: Int32(request.topK ?? 40),
            top_p: Float(request.topP ?? 0.95),
            seed: UInt32(request.seed ?? UInt64(Date().timeIntervalSince1970))
        )

        var error: UnsafeMutablePointer<CChar>?
        let output = cMessages.withUnsafeBufferPointer { buffer in
            llmr_generate_chat(engine, buffer.baseAddress, buffer.count, options, &error)
        }

        if let error {
            let message = String(cString: error)
            llmr_string_free(error)
            throw EmbeddedLlamaError.generationFailed(message)
        }

        guard let output else {
            throw EmbeddedLlamaError.generationFailed("Embedded llama returned no output.")
        }

        let text = String(cString: output)
        llmr_string_free(output)

        return ChatCompletionResult(
            id: "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            model: model.id,
            content: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func generateChatStream(model: AppConfig.Model, request: ChatCompletionRequest, state: EmbeddedStreamState) throws {
        try ensureLoaded(model: model)

        guard let engine else {
            throw EmbeddedLlamaError.notLoaded
        }

        let cMessages = request.messages.map { message in
            llmr_message(
                role: strdup(message.role),
                content: strdup(message.content)
            )
        }

        defer {
            for message in cMessages {
                free(UnsafeMutableRawPointer(mutating: message.role))
                free(UnsafeMutableRawPointer(mutating: message.content))
            }
        }

        let options = generationOptions(
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            seed: request.seed
        )

        let retainedState = Unmanaged.passRetained(state)
        defer {
            retainedState.release()
        }

        var error: UnsafeMutablePointer<CChar>?
        let output = cMessages.withUnsafeBufferPointer { buffer in
            llmr_generate_chat_stream(
                engine,
                buffer.baseAddress,
                buffer.count,
                options,
                embeddedTokenCallback,
                retainedState.toOpaque(),
                &error
            )
        }

        if let output {
            llmr_string_free(output)
        }

        if let error {
            let message = String(cString: error)
            llmr_string_free(error)
            throw EmbeddedLlamaError.generationFailed(message)
        }
    }

    func generateCompletion(model: AppConfig.Model, request: CompletionRequest) throws -> CompletionResult {
        try ensureLoaded(model: model)

        guard let engine else {
            throw EmbeddedLlamaError.notLoaded
        }

        let options = generationOptions(
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            seed: request.seed
        )

        var error: UnsafeMutablePointer<CChar>?
        let output = llmr_generate_completion(engine, request.prompt, options, nil, nil, &error)

        if let error {
            let message = String(cString: error)
            llmr_string_free(error)
            throw EmbeddedLlamaError.generationFailed(message)
        }

        guard let output else {
            throw EmbeddedLlamaError.generationFailed("Embedded llama returned no output.")
        }

        let text = String(cString: output)
        llmr_string_free(output)

        return CompletionResult(
            id: "cmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            model: model.id,
            text: text
        )
    }

    func generateCompletionStream(model: AppConfig.Model, request: CompletionRequest, state: EmbeddedStreamState) throws {
        try ensureLoaded(model: model)

        guard let engine else {
            throw EmbeddedLlamaError.notLoaded
        }

        let options = generationOptions(
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            seed: request.seed
        )

        let retainedState = Unmanaged.passRetained(state)
        defer {
            retainedState.release()
        }

        var error: UnsafeMutablePointer<CChar>?
        let output = llmr_generate_completion(
            engine,
            request.prompt,
            options,
            embeddedTokenCallback,
            retainedState.toOpaque(),
            &error
        )

        if let output {
            llmr_string_free(output)
        }

        if let error {
            let message = String(cString: error)
            llmr_string_free(error)
            throw EmbeddedLlamaError.generationFailed(message)
        }
    }

    func embed(model: AppConfig.Model, input: String) throws -> [Float] {
        let path = NSString(string: model.path).expandingTildeInPath
        let contextSize = Int32(model.contextSize ?? 8192)
        let gpuLayers = Int32(model.gpuLayers ?? 99)

        var error: UnsafeMutablePointer<CChar>?
        let result = llmr_embed_text(path, contextSize, gpuLayers, input, &error)

        if let error {
            let message = String(cString: error)
            llmr_string_free(error)
            throw EmbeddedLlamaError.generationFailed(message)
        }

        guard let values = result.values, result.count > 0 else {
            throw EmbeddedLlamaError.generationFailed("Embedded llama returned no embeddings.")
        }

        let vector = Array(UnsafeBufferPointer(start: values, count: Int(result.count)))
        llmr_embedding_result_free(result)
        return vector
    }

    func unload() {
        if let engine {
            llmr_engine_free(engine)
        }

        engine = nil
        activeModelID = nil
    }

    private func ensureLoaded(model: AppConfig.Model) throws {
        if activeModelID == model.id, engine != nil {
            return
        }

        unload()

        let path = NSString(string: model.path).expandingTildeInPath
        let contextSize = Int32(model.contextSize ?? 8192)
        let gpuLayers = Int32(model.gpuLayers ?? 99)

        var error: UnsafeMutablePointer<CChar>?
        let created = llmr_engine_create(path, contextSize, gpuLayers, &error)

        if let error {
            let message = String(cString: error)
            llmr_string_free(error)
            throw EmbeddedLlamaError.loadFailed(message)
        }

        guard let created else {
            throw EmbeddedLlamaError.loadFailed("Embedded llama failed to create an engine.")
        }

        engine = created
        activeModelID = model.id
    }

    private func generationOptions(
        maxTokens: Int?,
        temperature: Double?,
        topP: Double?,
        topK: Int?,
        seed: UInt64?
    ) -> llmr_generation_options {
        llmr_generation_options(
            max_tokens: Int32(maxTokens ?? 256),
            temperature: Float(temperature ?? 0.2),
            top_k: Int32(topK ?? 40),
            top_p: Float(topP ?? 0.95),
            seed: UInt32(seed ?? UInt64(Date().timeIntervalSince1970))
        )
    }
}

final class EmbeddedStreamState: @unchecked Sendable {
    let onToken: @Sendable (String) -> Void

    init(onToken: @escaping @Sendable (String) -> Void) {
        self.onToken = onToken
    }

    func yield(bytes: UnsafePointer<CChar>, length: Int) {
        let data = Data(bytes: bytes, count: length)
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            onToken(text)
        }
    }
}

private let embeddedTokenCallback: llmr_token_callback = { bytes, length, userData in
    guard let bytes, let userData else {
        return
    }

    let state = Unmanaged<EmbeddedStreamState>.fromOpaque(userData).takeUnretainedValue()
    state.yield(bytes: bytes, length: length)
}

struct ChatCompletionRequest {
    struct Message {
        var role: String
        var content: String
    }

    var model: String?
    var messages: [Message]
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var seed: UInt64?
    var stream: Bool

    init(json: [String: Any]) throws {
        model = json["model"] as? String

        guard let rawMessages = json["messages"] as? [[String: Any]], !rawMessages.isEmpty else {
            throw EmbeddedLlamaError.invalidRequest("messages must be a non-empty array.")
        }

        messages = try rawMessages.map { raw in
            guard let role = raw["role"] as? String, let content = raw["content"] as? String else {
                throw EmbeddedLlamaError.invalidRequest("Each message must include string role and content fields.")
            }

            return Message(role: role, content: content)
        }

        maxTokens = json["max_tokens"] as? Int
        temperature = json["temperature"] as? Double
        topP = json["top_p"] as? Double
        topK = json["top_k"] as? Int
        seed = (json["seed"] as? NSNumber)?.uint64Value
        stream = (json["stream"] as? Bool) ?? false
    }
}

struct ChatCompletionResult {
    var id: String
    var model: String
    var content: String
}

struct CompletionRequest {
    var model: String?
    var prompt: String
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var seed: UInt64?
    var stream: Bool

    init(json: [String: Any]) throws {
        model = json["model"] as? String

        if let prompt = json["prompt"] as? String {
            self.prompt = prompt
        } else if let prompts = json["prompt"] as? [String], let first = prompts.first {
            self.prompt = first
        } else {
            throw EmbeddedLlamaError.invalidRequest("prompt must be a string.")
        }

        maxTokens = json["max_tokens"] as? Int
        temperature = json["temperature"] as? Double
        topP = json["top_p"] as? Double
        topK = json["top_k"] as? Int
        seed = (json["seed"] as? NSNumber)?.uint64Value
        stream = (json["stream"] as? Bool) ?? false
    }
}

struct CompletionResult {
    var id: String
    var model: String
    var text: String
}

struct EmbeddingRequest {
    var model: String?
    var inputs: [String]

    init(json: [String: Any]) throws {
        model = json["model"] as? String

        if let input = json["input"] as? String {
            inputs = [input]
        } else if let input = json["input"] as? [String] {
            inputs = input
        } else {
            throw EmbeddedLlamaError.invalidRequest("input must be a string or array of strings.")
        }
    }
}

enum EmbeddedLlamaError: LocalizedError {
    case notLoaded
    case loadFailed(String)
    case generationFailed(String)
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Embedded llama engine is not loaded."
        case .loadFailed(let message), .generationFailed(let message), .invalidRequest(let message):
            return message
        }
    }
}
