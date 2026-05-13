import Foundation

enum BackendExecutableResolver {
    static func resolve(_ configuredValue: String) throws -> URL {
        let expanded = NSString(string: configuredValue).expandingTildeInPath
        let fileManager = FileManager.default

        for candidate in candidates(for: expanded) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw BackendError.missingExecutable(configuredValue: configuredValue, searched: candidates(for: expanded).map(\.path))
    }

    private static func candidates(for value: String) -> [URL] {
        var candidates: [URL] = []

        if value.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: value))
            return candidates
        }

        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let resourceDirectory = Bundle.main.resourceURL
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        if value.contains("/") {
            candidates.append(currentDirectory.appendingPathComponent(value))

            if let executableDirectory {
                candidates.append(executableDirectory.appendingPathComponent(value))
            }

            if let resourceDirectory {
                candidates.append(resourceDirectory.appendingPathComponent(value))
            }
        } else {
            if let resourceDirectory {
                candidates.append(resourceDirectory.appendingPathComponent(value))
                candidates.append(resourceDirectory.appendingPathComponent("bin").appendingPathComponent(value))
            }

            if let executableDirectory {
                candidates.append(executableDirectory.appendingPathComponent(value))
                candidates.append(executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(value))
            }

            candidates.append(currentDirectory.appendingPathComponent(value))
            candidates.append(contentsOf: pathCandidates(named: value))
        }

        return Array(NSOrderedSet(array: candidates).compactMap { $0 as? URL })
    }

    private static func pathCandidates(named executableName: String) -> [URL] {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else {
            return []
        }

        return path
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(executableName) }
    }
}
