// swift-tools-version: 6.0
import PackageDescription
import Foundation

let libraryPath = ProcessInfo.processInfo.environment["LLMRUNNER_LIBRARY_PATH"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/llama-install/lib").path

let package = Package(
    name: "LLMRunner",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "llmrunner", targets: ["LLMRunner"])],
    targets: [
        .systemLibrary(name: "CLlama", pkgConfig: "llama"),
        .target(name: "EmbeddedLlamaC", dependencies: ["CLlama"],
                cSettings: [.headerSearchPath("include")]),
        .executableTarget(name: "LLMRunner", dependencies: ["EmbeddedLlamaC"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", libraryPath,
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Resources/lib"])]),
        .testTarget(name: "LLMRunnerTests", dependencies: ["LLMRunner"])
    ]
)
