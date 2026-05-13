import Foundation
import Network

final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let handler: Handler
    private let requestLogging: Bool
    private let maxRequestBodyBytes: Int
    private var listener: NWListener?

    init(
        host: String,
        port: UInt16,
        requestLogging: Bool = true,
        maxRequestBodyBytes: Int = 10_485_760,
        handler: @escaping Handler
    ) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.requestLogging = requestLogging
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.handler = handler
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [handler, requestLogging, maxRequestBodyBytes] connection in
            connection.start(queue: .global(qos: .userInitiated))

            Task {
                await Self.handle(
                    connection: connection,
                    requestLogging: requestLogging,
                    maxRequestBodyBytes: maxRequestBodyBytes,
                    handler: handler
                )
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        AppLogger.info("llmrunner listening on http://\(host):\(port)/v1")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume()
                default:
                    break
                }
            }
        }
    }

    func stop() {
        listener?.cancel()
    }

    private static func handle(
        connection: NWConnection,
        requestLogging: Bool,
        maxRequestBodyBytes: Int,
        handler: @escaping Handler
    ) async {
        let started = Date()
        var parsedRequest: HTTPRequest?
        var statusCode = 400

        defer {
            if requestLogging, let request = parsedRequest {
                AppLogger.request(request, statusCode: statusCode, duration: Date().timeIntervalSince(started))
            }
        }

        do {
            let data = try await readRequestData(from: connection, maxBodyBytes: maxRequestBodyBytes)
            let request = try parseRequest(data)
            parsedRequest = request
            let response = await handler(request)
            statusCode = response.statusCode
            if let streamBody = response.streamBody {
                try await send(response.serializedHeaders(includeContentLength: false), to: connection)
                for try await chunk in streamBody {
                    try await send(chunk, to: connection)
                }
            } else {
                try await send(response.serialized(), to: connection)
            }
        } catch {
            AppLogger.warning("request failed before routing: \(error.localizedDescription)")
            let response = HTTPResponse.json(
                statusCode: (error as? HTTPParseError)?.statusCode ?? 400,
                object: [
                    "error": [
                        "message": error.localizedDescription,
                        "type": "invalid_request_error"
                    ]
                ]
            )
            try? await send(response.serialized(), to: connection)
        }

        connection.cancel()
    }

    private static func readRequestData(from connection: NWConnection, maxBodyBytes: Int) async throws -> Data {
        var buffer = Data()
        var expectedLength: Int?

        while true {
            let chunk = try await receive(from: connection)
            guard !chunk.isEmpty else {
                return buffer
            }

            buffer.append(chunk)

            if expectedLength == nil, let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerEnd = headerRange.upperBound
                let headerData = buffer[..<headerRange.lowerBound]
                let headerText = String(decoding: headerData, as: UTF8.self)
                let contentLength = contentLength(from: headerText)
                if contentLength > maxBodyBytes {
                    throw HTTPParseError.requestBodyTooLarge(maxBytes: maxBodyBytes)
                }
                expectedLength = headerEnd + contentLength
            }

            if let expectedLength, buffer.count >= expectedLength {
                return buffer
            }
        }
    }

    private static func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func parseRequest(_ data: Data) throws -> HTTPRequest {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw HTTPParseError.missingHeaders
        }

        let headerData = data[..<headerRange.lowerBound]
        let body = data[headerRange.upperBound...]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")

        guard let requestLine = lines.first else {
            throw HTTPParseError.missingRequestLine
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else {
            throw HTTPParseError.invalidRequestLine
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }

            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        return HTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            version: requestParts[2],
            headers: headers,
            body: Data(body)
        )
    }

    private static func contentLength(from headerText: String) -> Int {
        for line in headerText.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else {
                continue
            }

            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }

        return 0
    }
}

enum HTTPParseError: LocalizedError {
    case missingHeaders
    case missingRequestLine
    case invalidRequestLine
    case requestBodyTooLarge(maxBytes: Int)

    var errorDescription: String? {
        switch self {
        case .missingHeaders: "The request did not include HTTP headers."
        case .missingRequestLine: "The request did not include a request line."
        case .invalidRequestLine: "The request line is invalid."
        case .requestBodyTooLarge(let maxBytes): "The request body exceeds the configured limit of \(maxBytes) bytes."
        }
    }

    var statusCode: Int {
        switch self {
        case .requestBodyTooLarge: 413
        default: 400
        }
    }
}
