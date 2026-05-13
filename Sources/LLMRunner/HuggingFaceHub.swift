import Foundation

struct HuggingFaceModel: Sendable {
    var id: String
    var downloads: Int?
    var likes: Int?
    var siblings: [String]
}

struct GGUFSelection: Sendable {
    var repoID: String
    var filename: String
    var downloadURL: URL
}

enum HuggingFaceHub {
    private static let baseURL = URL(string: "https://huggingface.co")!
    private static let preferredQuantizations = [
        "Q4_K_M",
        "Q5_K_M",
        "Q4_K_S",
        "Q4_0",
        "Q8_0"
    ]

    static func search(query: String, limit: Int) async throws -> [HuggingFaceModel] {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "full", value: "true")
        ]

        let object = try await getJSON(url: components.url!)
        guard let array = object as? [[String: Any]] else {
            return []
        }

        return array.compactMap(parseModel)
    }

    static func modelInfo(repoID: String) async throws -> HuggingFaceModel {
        let encodedRepo = repoID.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let url = baseURL.appendingPathComponent("/api/models/\(encodedRepo)")
        let object = try await getJSON(url: url)

        guard let dictionary = object as? [String: Any], let model = parseModel(dictionary) else {
            throw CLIError.huggingFace("Could not parse model info for \(repoID).")
        }

        return model
    }

    static func resolveGGUF(repoID: String, quantization: String?, filename: String?) async throws -> GGUFSelection {
        let model = try await modelInfo(repoID: repoID)
        guard let selected = selectGGUFFile(from: model.siblings, quantization: quantization, filename: filename) else {
            throw CLIError.noGGUFFiles(repoID)
        }

        return selection(repoID: repoID, filename: selected)
    }

    static func resolveSearch(query: String, quantization: String?, filename: String?) async throws -> GGUFSelection {
        let results = try await search(query: query, limit: 10)

        for model in results {
            if let selected = selectGGUFFile(from: model.siblings, quantization: quantization, filename: filename) {
                return selection(repoID: model.id, filename: selected)
            }
        }

        throw CLIError.noModelsFound(query)
    }

    static func ggufFiles(repoID: String) async throws -> [String] {
        let model = try await modelInfo(repoID: repoID)
        return sortGGUFFiles(model.siblings)
    }

    private static func selection(repoID: String, filename: String) -> GGUFSelection {
        let encodedRepo = repoID.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let encodedFilename = filename
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let url = baseURL.appendingPathComponent("\(encodedRepo)/resolve/main/\(encodedFilename)")

        return GGUFSelection(repoID: repoID, filename: filename, downloadURL: url)
    }

    private static func selectGGUFFile(from files: [String], quantization: String?, filename: String?) -> String? {
        let ggufFiles = sortGGUFFiles(files)

        if let filename {
            return ggufFiles.first { $0 == filename || $0.hasSuffix("/\(filename)") }
        }

        if let quantization {
            return ggufFiles.first { $0.localizedCaseInsensitiveContains(quantization) }
        }

        for quantization in preferredQuantizations {
            if let match = ggufFiles.first(where: { $0.localizedCaseInsensitiveContains(quantization) }) {
                return match
            }
        }

        return ggufFiles.first
    }

    private static func sortGGUFFiles(_ files: [String]) -> [String] {
        files
            .filter { $0.lowercased().hasSuffix(".gguf") }
            .sorted { lhs, rhs in
                score(lhs) > score(rhs)
            }
    }

    private static func score(_ filename: String) -> Int {
        for (index, quantization) in preferredQuantizations.enumerated() {
            if filename.localizedCaseInsensitiveContains(quantization) {
                return preferredQuantizations.count - index
            }
        }

        return 0
    }

    private static func parseModel(_ dictionary: [String: Any]) -> HuggingFaceModel? {
        guard let id = dictionary["id"] as? String else {
            return nil
        }

        let siblings = (dictionary["siblings"] as? [[String: Any]])?
            .compactMap { $0["rfilename"] as? String } ?? []

        return HuggingFaceModel(
            id: id,
            downloads: dictionary["downloads"] as? Int,
            likes: dictionary["likes"] as? Int,
            siblings: siblings
        )
    }

    private static func getJSON(url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue("llmrunner/0.1", forHTTPHeaderField: "User-Agent")

        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CLIError.huggingFace("Hugging Face returned HTTP \(httpResponse.statusCode): \(body)")
        }

        return try JSONSerialization.jsonObject(with: data)
    }
}
