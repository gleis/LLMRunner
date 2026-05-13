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
