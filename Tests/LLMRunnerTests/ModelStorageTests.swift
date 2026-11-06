import Foundation
import Testing
@testable import LLMRunner

struct ModelStorageTests {
    @Test func pruningPreservesConfiguredModelsAndExternalPaths() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        for name in ["kept", "orphan", ".hidden", "outside"] {
            try manager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: root.appendingPathComponent(name + "/weights.gguf"))
        }
        try manager.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.appendingPathComponent("outside"))
        let paths = [root.appendingPathComponent("kept/weights.gguf").path, root.appendingPathComponent("outside/weights.gguf").path]
        let candidates = try ModelStorage.orphanDirectories(root: root, configuredPaths: paths)
        #expect(candidates.map(\.lastPathComponent) == ["orphan"])
        #expect(ModelStorage.bytes(at: root.appendingPathComponent("orphan")) == 3)
        #expect(manager.fileExists(atPath: root.appendingPathComponent("kept/weights.gguf").path))
    }
}
