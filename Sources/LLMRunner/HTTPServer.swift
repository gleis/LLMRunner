import Foundation
import Network

final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let handler: Handler
    private var listener: NWListener?

    init(host: String, port: UInt16, handler: @escaping Handler) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.handler = handler
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [handler] connection in
            connection.start(queue: .global(qos: .userInitiated))

            Task {
                await Self.handle(connection: connection, handler: handler)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        print("llmrunner listening on http://\(host):\(port)/v1")

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

    private static func handle(connection: NWConnection, handler: @escaping Handler) async {
        do {
            let data = try await readRequestData(from: connection)
            let request = try parseRequest(data)
            let response = await handler(request)
            if let streamBody = response.streamBody {
                try await send(response.serializedHeaders(includeContentLength: false), to: connection)
                for try await chunk in streamBody {
                    try await send(chunk, to: connection)
                }
            } else {
                try await send(response.serialized(), to: connection)
            }
        } catch {
            let response = HTTPResponse.json(
                statusCode: 400,
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

    private static func readRequestData(from connection: NWConnection) async throws -> Data {
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

    var errorDescription: String? {
        switch self {
        case .missingHeaders: "The request did not include HTTP headers."
        case .missingRequestLine: "The request did not include a request line."
        case .invalidRequestLine: "The request line is invalid."
        }
    }
}
