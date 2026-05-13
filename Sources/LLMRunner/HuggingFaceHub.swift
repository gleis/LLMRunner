import Foundation

struct HuggingFaceModel: Sendable {
    var id: String
    var downloads: Int?
    var likes: Int?
    var siblings: [String]
    var files: [HuggingFaceFile]
}

struct HuggingFaceFile: Sendable {
    var name: String
    var sizeBytes: Int64?
}

struct GGUFSelection: Sendable {
    var repoID: String
    var filename: String
    var downloadURL: URL
    var sizeBytes: Int64?
    var quantization: String?
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
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/models/\(encodedRepo)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "blobs", value: "true")
        ]
        let object = try await getJSON(url: components.url!)

        guard let dictionary = object as? [String: Any], let model = parseModel(dictionary) else {
            throw CLIError.huggingFace("Could not parse model info for \(repoID).")
        }

        return model
    }

    static func resolveGGUF(repoID: String, quantization: String?, filename: String?) async throws -> GGUFSelection {
        let model = try await modelInfo(repoID: repoID)
        guard let selected = selectGGUFFile(from: model.files, quantization: quantization, filename: filename) else {
            throw CLIError.noGGUFFiles(repoID)
        }

        return selection(repoID: repoID, file: selected)
    }

    static func resolveSearch(query: String, quantization: String?, filename: String?) async throws -> GGUFSelection {
        let results = try await search(query: query, limit: 10)

        for model in results {
            let detailedModel = (try? await modelInfo(repoID: model.id)) ?? model
            if let selected = selectGGUFFile(from: detailedModel.files, quantization: quantization, filename: filename) {
                return selection(repoID: detailedModel.id, file: selected)
            }
        }

        throw CLIError.noModelsFound(query)
    }

    static func ggufFiles(repoID: String) async throws -> [String] {
        try await ggufFileInfos(repoID: repoID).map(\.name)
    }

    static func ggufFileInfos(repoID: String) async throws -> [HuggingFaceFile] {
        let model = try await modelInfo(repoID: repoID)
        return sortGGUFFiles(model.files)
    }

    static func recommendedFile(for model: HuggingFaceModel) -> HuggingFaceFile? {
        selectGGUFFile(from: model.files, quantization: nil, filename: nil)
    }

    static func quantization(from filename: String) -> String? {
        for quantization in preferredQuantizations where filename.localizedCaseInsensitiveContains(quantization) {
            return quantization
        }

        let pattern = #"(?i)(?:^|[-_.])((?:IQ|Q)\d(?:_[A-Z0-9]+)+)(?:[-_.]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard
            let match = regex.firstMatch(in: filename, range: range),
            match.numberOfRanges > 1,
            let quantizationRange = Range(match.range(at: 1), in: filename)
        else {
            return nil
        }

        return String(filename[quantizationRange]).uppercased()
    }

    private static func selection(repoID: String, file: HuggingFaceFile) -> GGUFSelection {
        let encodedRepo = repoID.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let encodedFilename = file.name
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let url = baseURL.appendingPathComponent("\(encodedRepo)/resolve/main/\(encodedFilename)")

        return GGUFSelection(
            repoID: repoID,
            filename: file.name,
            downloadURL: url,
            sizeBytes: file.sizeBytes,
            quantization: quantization(from: file.name)
        )
    }

    private static func selectGGUFFile(from files: [HuggingFaceFile], quantization: String?, filename: String?) -> HuggingFaceFile? {
        let ggufFiles = sortGGUFFiles(files)

        if let filename {
            return ggufFiles.first { $0.name == filename || $0.name.hasSuffix("/\(filename)") }
        }

        if let quantization {
            return ggufFiles.first { $0.name.localizedCaseInsensitiveContains(quantization) }
        }

        for quantization in preferredQuantizations {
            if let match = ggufFiles.first(where: { $0.name.localizedCaseInsensitiveContains(quantization) }) {
                return match
            }
        }

        return ggufFiles.first
    }

    private static func sortGGUFFiles(_ files: [HuggingFaceFile]) -> [HuggingFaceFile] {
        files
            .filter { $0.name.lowercased().hasSuffix(".gguf") }
            .sorted { lhs, rhs in
                score(lhs.name) > score(rhs.name)
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

        let files = (dictionary["siblings"] as? [[String: Any]])?
            .compactMap(parseFile) ?? []

        return HuggingFaceModel(
            id: id,
            downloads: dictionary["downloads"] as? Int,
            likes: dictionary["likes"] as? Int,
            siblings: files.map(\.name),
            files: files
        )
    }

    private static func parseFile(_ dictionary: [String: Any]) -> HuggingFaceFile? {
        guard let name = dictionary["rfilename"] as? String else {
            return nil
        }

        return HuggingFaceFile(
            name: name,
            sizeBytes: int64(dictionary["size"]) ?? int64((dictionary["lfs"] as? [String: Any])?["size"])
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let int as Int:
            return Int64(int)
        case let int64 as Int64:
            return int64
        default:
            return nil
        }
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
