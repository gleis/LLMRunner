import Foundation

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var version: String
    var headers: [String: String]
    var body: Data

    var querylessPath: String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    func jsonObject() throws -> [String: Any] {
        guard !body.isEmpty else {
            return [:]
        }

        let object = try JSONSerialization.jsonObject(with: body)
        return object as? [String: Any] ?? [:]
    }
}

struct HTTPResponse: Sendable {
    var statusCode: Int
    var reason: String
    var headers: [String: String]
    var body: Data

    static func json(statusCode: Int = 200, object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data()
        return HTTPResponse(
            statusCode: statusCode,
            reason: HTTPStatus.reason(for: statusCode),
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(data.count)"
            ],
            body: data
        )
    }

    static func text(statusCode: Int, _ message: String) -> HTTPResponse {
        let data = Data(message.utf8)
        return HTTPResponse(
            statusCode: statusCode,
            reason: HTTPStatus.reason(for: statusCode),
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "\(data.count)"
            ],
            body: data
        )
    }

    func serialized() -> Data {
        var data = Data()
        data.append("HTTP/1.1 \(statusCode) \(reason)\r\n")

        var mergedHeaders = headers
        mergedHeaders["Connection"] = "close"
        mergedHeaders["Content-Length"] = "\(body.count)"

        for (name, value) in mergedHeaders.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            data.append("\(name): \(value)\r\n")
        }

        data.append("\r\n")
        data.append(body)
        return data
    }
}

enum HTTPStatus {
    static func reason(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "HTTP \(statusCode)"
        }
    }
}

extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
