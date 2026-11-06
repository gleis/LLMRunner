import Foundation
import Testing
@testable import LLMRunner

struct SecurityTests {
    private func config() -> AppConfig {
        var value = AppConfig.defaultConfig()
        value.security?.apiKeyEnv = nil
        return value
    }
    private func service(_ config: AppConfig) -> OpenAIService {
        OpenAIService(config: config, supervisor: ModelSupervisor(config: config), embeddedBackend: EmbeddedLlamaBackend())
    }
    private func request(_ path: String, headers: [String: String] = [:], method: String = "GET") -> HTTPRequest {
        HTTPRequest(method: method, path: path, version: "HTTP/1.1", headers: headers, body: Data())
    }
    @Test func remoteBindingRequiresResolvedNonblankKey() throws {
        var value = config()
        for host in ["0.0.0.0", "::", "192.168.1.2", "example.com"] {
            value.server.host = host
            #expect(throws: SecurityError.self) { try value.validateSecurity(environment: [:]) }
            value.security?.apiKeys = ["  "]
            #expect(throws: SecurityError.self) { try value.validateSecurity(environment: [:]) }
        }
        value.security?.apiKeyEnv = " TEST_KEY "
        #expect(throws: SecurityError.self) { try value.validateSecurity(environment: [:]) }
        try value.validateSecurity(environment: ["TEST_KEY": " secret "])
    }
    @Test func anonymousLoopbackIsCompatible() async throws {
        for host in ["127.0.0.1", "::1", "localhost"] {
            var value = config(); value.server.host = host
            try value.validateSecurity(environment: [:])
            #expect(await service(value).handle(request("/v1/models")).statusCode == 200)
        }
    }
    @Test func remoteServiceFailsClosedForBothBackends() async {
        for mode in ["embedded", "server"] {
            var value = config(); value.server.host = "0.0.0.0"; value.backend.mode = mode
            let api = service(value)
            #expect(await api.handle(request("/v1/chat/completions", method: "POST")).statusCode == 401)
            #expect(await api.handle(request("/v1/embeddings", headers: ["authorization": "Bearer arbitrary"], method: "POST")).statusCode == 401)
            #expect(await api.handle(request("/health")).statusCode == 200)
            #expect(await api.handle(request("/health", method: "POST")).statusCode == 401)
        }
    }
    @Test func keyTransportsScopesAndLimits() async {
        var value = config()
        value.security?.apiKeys = ["valid", "restricted"]
        value.security?.requestsPerMinute = 2
        value.security?.keyScopes = ["restricted": ["/v1/models"]]
        let api = service(value)
        #expect(await api.handle(request("/v1/models")).statusCode == 401)
        #expect(await api.handle(request("/v1/models", headers: ["authorization": "Bearer wrong"])).statusCode == 401)
        #expect(await api.handle(request("/v1/models", headers: ["authorization": "Bearer valid"])).statusCode == 200)
        #expect(await api.handle(request("/v1/models", headers: ["x-api-key": "valid"])).statusCode == 200)
        let limited = await api.handle(request("/v1/models", headers: ["x-api-key": "valid"]))
        #expect(limited.statusCode == 429)
        #expect(limited.headers["Retry-After"] == "60")
        #expect(await api.handle(request("/v1/embeddings", headers: ["x-api-key": "restricted"], method: "POST")).statusCode == 403)
        #expect(await api.handle(request("/v1/models", headers: ["x-api-key": "restricted"])).statusCode == 200)
    }
    @Test func rateWindowResetAndConcurrentRequests() async {
        let limiter = RequestLimiter()
        #expect(await limiter.allow(key: "a", limit: 1, now: 0))
        #expect(!(await limiter.allow(key: "a", limit: 1, now: 59)))
        #expect(await limiter.allow(key: "a", limit: 1, now: 60))
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { await limiter.allow(key: "concurrent", limit: 5, now: 0) } }
            var count = 0
            for await allowed in group { if allowed { count += 1 } }
            return count
        }
        #expect(accepted == 5)
    }
    @Test func backendCannotBypassFrontendAuthentication() throws {
        var value = config(); value.backend.mode = "server"; value.backend.host = "0.0.0.0"
        #expect(throws: SecurityError.self) { try value.validateSecurity(environment: [:]) }
        value.backend.host = "127.0.0.1"; value.backend.extraArguments = ["--host=0.0.0.0"]
        #expect(throws: SecurityError.self) { try value.validateSecurity(environment: [:]) }
    }
    @Test func scopeKeysCannotSilentlyLoseTheirRestrictions() throws {
        var value = config(); value.security?.apiKeys = ["valid"]
        value.security?.keyScopes = [" valid ": ["/v1/models"]]
        #expect(throws: SecurityError.self) { try value.validateSecurity(environment: [:]) }
        value.security?.keyScopes = ["valid": ["/v1/models"]]
        try value.validateSecurity(environment: [:])
    }
}
