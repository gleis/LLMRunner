import Foundation

enum ModelsCLI {
    private struct CatalogEntry {
        var id: String
        var repoID: String
        var quantization: String?
    }

    private static let catalog: [String: CatalogEntry] = [
        "tiny": CatalogEntry(
            id: "smollm2-135m",
            repoID: "jc-builds/SmolLM2-135M-Instruct-Q4_K_M-GGUF",
            quantization: "Q4_K_M"
        )
    ]

    static func run(arguments: [String]) async throws {
        let subcommand = Array(arguments.dropFirst(2)).first ?? "list"

        switch subcommand {
        case "list":
            try list(arguments: arguments)
        case "search":
            try await search(arguments: arguments)
        case "files":
            try await files(arguments: arguments)
        case "pull":
            try await pull(arguments: arguments)
        case "delete", "rm", "remove":
            try delete(arguments: arguments)
        default:
            throw CLIError.unknownCommand("models \(subcommand)")
        }
    }

    private static func list(arguments: [String]) throws {
        let config = try AppConfig.loadOrCreate(arguments: arguments)

        if config.models.isEmpty {
            print("No models configured.")
            return
        }

        for model in config.models {
            let path = NSString(string: model.path).expandingTildeInPath
            let exists = FileManager.default.fileExists(atPath: path)
            let marker = model.id == config.defaultModel ? "*" : " "
            let size = fileSizeDescription(path: path)
            print("\(marker) \(model.id) \(exists ? "installed" : "missing") \(size) \(path)")
        }
    }

    private static func search(arguments: [String]) async throws {
        let values = Array(arguments.dropFirst())
        let query = positionalArguments(after: "search", in: values).joined(separator: " ")

        guard !query.isEmpty else {
            throw CLIError.missingArgument("search query")
        }

        let limit = Int(optionValue("--limit", in: values) ?? "10") ?? 10
        let results = try await HuggingFaceHub.search(query: query, limit: limit)

        if results.isEmpty {
            print("No GGUF model repos found for '\(query)'.")
            return
        }

        for model in results {
            let detailedModel = (try? await HuggingFaceHub.modelInfo(repoID: model.id)) ?? model
            let ggufFiles = detailedModel.files.filter { $0.name.lowercased().hasSuffix(".gguf") }
            let downloads = model.downloads.map(String.init) ?? "-"
            let likes = model.likes.map(String.init) ?? "-"
            let recommendation = HuggingFaceHub.recommendedFile(for: detailedModel)
                .map(recommendationDescription(file:))
                ?? "no recommended GGUF"
            print("\(model.id)  downloads:\(downloads) likes:\(likes) gguf:\(ggufFiles.count)")
            print("  recommended: \(recommendation)")
        }
    }

    private static func files(arguments: [String]) async throws {
        let values = Array(arguments.dropFirst())
        guard let repoID = positionalArguments(after: "files", in: values).first else {
            throw CLIError.missingArgument("repo id")
        }

        let files = try await HuggingFaceHub.ggufFileInfos(repoID: repoID)

        if files.isEmpty {
            print("No GGUF files found in \(repoID).")
            return
        }

        let recommended = HuggingFaceHub.recommendedFile(for: HuggingFaceModel(
            id: repoID,
            downloads: nil,
            likes: nil,
            siblings: files.map(\.name),
            files: files
        ))

        for file in files {
            let marker = file.name == recommended?.name ? "*" : " "
            print("\(marker) \(fileDescription(file: file))")
        }
    }

    private static func pull(arguments: [String]) async throws {
        let values = Array(arguments.dropFirst())
        let positionals = positionalArguments(after: "pull", in: values)
        guard !positionals.isEmpty else {
            throw CLIError.missingArgument("model, repo, alias, or search query")
        }

        let requested = positionals.joined(separator: " ")
        let resolution = try await resolvePullSource(requested: requested, arguments: values)
        let id = optionValue("--id", in: values) ?? resolution.id
        let sourceURL = resolution.url

        try RuntimePaths.ensureRuntimeDirectory()

        let configURL = AppConfig.resolvedConfigURL(arguments: arguments)
        var config = try AppConfig.loadOrCreate(arguments: arguments)

        let filename = optionValue("--filename", in: values)
            ?? sourceURL.lastPathComponent.nonEmpty
            ?? "\(id).gguf"

        let modelDirectory = RuntimePaths.modelsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let destination = modelDirectory.appendingPathComponent(filename)

        print(resolution.message)
        print("Pulling \(id) from \(sourceURL.absoluteString)")
        if let details = resolution.details {
            print("Selected \(details)")
        }
        try await download(from: sourceURL, to: destination)

        let model = AppConfig.Model(
            id: id,
            path: destination.path,
            contextSize: nil,
            gpuLayers: 99,
            arguments: []
        )

        if let index = config.models.firstIndex(where: { $0.id == id }) {
            config.models[index] = model
        } else {
            config.models.append(model)
        }

        if config.defaultModel.isEmpty {
            config.defaultModel = id
        }

        try config.save(to: configURL)
        print("Installed \(id) at \(destination.path)")
    }

    private static func resolvePullSource(requested: String, arguments: [String]) async throws -> (id: String, url: URL, message: String, details: String?) {
        if let urlValue = optionValue("--url", in: arguments) {
            guard let sourceURL = URL(string: urlValue) else {
                throw CLIError.invalidURL(urlValue)
            }

            return (id: requested, url: sourceURL, message: "Using direct URL.", details: nil)
        }

        let quantization = optionValue("--quant", in: arguments)
        let filename = optionValue("--file", in: arguments) ?? optionValue("--filename", in: arguments)

        if let repoID = optionValue("--repo", in: arguments) {
            let selection = try await HuggingFaceHub.resolveGGUF(repoID: repoID, quantization: quantization, filename: filename)
            return (
                id: safeModelID(requested),
                url: selection.downloadURL,
                message: "Resolved \(repoID) -> \(selection.filename)",
                details: selectionDescription(selection)
            )
        }

        if let catalogEntry = catalog[requested.lowercased()] {
            let selection = try await HuggingFaceHub.resolveGGUF(
                repoID: catalogEntry.repoID,
                quantization: quantization ?? catalogEntry.quantization,
                filename: filename
            )
            return (
                id: catalogEntry.id,
                url: selection.downloadURL,
                message: "Resolved alias '\(requested)' -> \(selection.repoID) / \(selection.filename)",
                details: selectionDescription(selection)
            )
        }

        if requested.contains("/") && !requested.contains(" ") {
            let selection = try await HuggingFaceHub.resolveGGUF(repoID: requested, quantization: quantization, filename: filename)
            return (
                id: safeModelID(requested.split(separator: "/").last.map(String.init) ?? requested),
                url: selection.downloadURL,
                message: "Resolved \(selection.repoID) -> \(selection.filename)",
                details: selectionDescription(selection)
            )
        }

        let selection = try await HuggingFaceHub.resolveSearch(query: requested, quantization: quantization, filename: filename)
        return (
            id: safeModelID(selection.repoID.split(separator: "/").last.map(String.init) ?? requested),
            url: selection.downloadURL,
            message: "Resolved search '\(requested)' -> \(selection.repoID) / \(selection.filename)",
            details: selectionDescription(selection)
        )
    }

    private static func delete(arguments: [String]) throws {
        let values = Array(arguments.dropFirst())
        guard let id = values.dropFirst(2).first, !id.hasPrefix("-") else {
            throw CLIError.missingArgument("model id")
        }

        let configURL = AppConfig.resolvedConfigURL(arguments: arguments)
        var config = try AppConfig.loadOrCreate(arguments: arguments)

        guard let index = config.models.firstIndex(where: { $0.id == id }) else {
            throw CLIError.modelNotFound(id)
        }

        let model = config.models.remove(at: index)
        let modelPath = URL(fileURLWithPath: NSString(string: model.path).expandingTildeInPath)
        let managedDirectory = RuntimePaths.modelsDirectory.appendingPathComponent(id, isDirectory: true)

        if modelPath.path.hasPrefix(managedDirectory.path) {
            try? FileManager.default.removeItem(at: managedDirectory)
        } else {
            try? FileManager.default.removeItem(at: modelPath)
        }

        if config.defaultModel == id {
            config.defaultModel = config.models.first?.id ?? ""
        }

        try config.save(to: configURL)
        print("Deleted \(id).")
    }

    private static func download(from sourceURL: URL, to destination: URL) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        if sourceURL.isFileURL {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return
        }

        var request = URLRequest(url: sourceURL)
        request.setValue("llmrunner/0.1", forHTTPHeaderField: "User-Agent")

        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw CLIError.invalidURL("\(sourceURL.absoluteString) returned HTTP \(httpResponse.statusCode)")
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    private static func optionValue(_ name: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == name, index + 1 < arguments.count {
                return arguments[index + 1]
            }

            if argument.hasPrefix("\(name)=") {
                return String(argument.dropFirst(name.count + 1))
            }
        }

        return nil
    }

    private static func positionalArguments(after subcommand: String, in arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: subcommand) else {
            return []
        }

        var positionals: [String] = []
        var skipNext = false
        let optionsWithValues = Set(["--url", "--repo", "--quant", "--file", "--filename", "--id", "--limit", "--config"])

        for argument in arguments.dropFirst(index + 1) {
            if skipNext {
                skipNext = false
                continue
            }

            if argument.hasPrefix("--") {
                if optionsWithValues.contains(argument) {
                    skipNext = true
                }
                continue
            }

            positionals.append(argument)
        }

        return positionals
    }

    private static func safeModelID(_ value: String) -> String {
        let trimmed = value
            .replacingOccurrences(of: "-GGUF", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "_GGUF", with: "", options: [.caseInsensitive])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = trimmed.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let id = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return id.isEmpty ? "model" : id.lowercased()
    }

    private static func fileSizeDescription(path: String) -> String {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else {
            return "-"
        }

        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    private static func fileDescription(file: HuggingFaceFile) -> String {
        let quantization = HuggingFaceHub.quantization(from: file.name) ?? "unknown quant"
        let size = file.sizeBytes.map(byteCount) ?? "unknown size"
        return "\(file.name)  \(quantization)  \(size)"
    }

    private static func recommendationDescription(file: HuggingFaceFile) -> String {
        fileDescription(file: file)
    }

    private static func selectionDescription(_ selection: GGUFSelection) -> String {
        let quantization = selection.quantization ?? "unknown quant"
        let size = selection.sizeBytes.map(byteCount) ?? "unknown size"
        return "\(selection.filename)  \(quantization)  \(size)"
    }

    private static func byteCount(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
