import Foundation

enum ModelStorage {
    /// Only immediate, non-symlink managed directories that contain no configured model.
    /// External paths and loose files are never pruning candidates.
    static func orphanDirectories(root: URL, configuredPaths: [String]) throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        let references = configuredPaths.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { directory in
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
                let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
                return !references.contains { $0 == path || $0.hasPrefix(path + "/") }
            }
            .sorted { $0.path < $1.path }
    }

    static func bytes(at root: URL) -> Int64 {
        let manager = FileManager.default
        var total: Int64 = 0
        guard let items = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return 0 }
        for case let file as URL in items {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
