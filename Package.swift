// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LLMRunner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "llmrunner", targets: ["LLMRunner"])
    ],
    targets: [
        .target(
            name: "EmbeddedLlamaC",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags([
                    "-I/opt/homebrew/opt/llama.cpp/include",
                    "-I/opt/homebrew/opt/ggml/include"
                ])
            ]
        ),
        .executableTarget(
            name: "LLMRunner",
            dependencies: ["EmbeddedLlamaC"],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/llama.cpp/lib",
                    "-L/opt/homebrew/opt/ggml/lib",
                    "-lllama",
                    "-lggml",
                    "-lggml-base",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Resources/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/opt/llama.cpp/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/opt/ggml/lib"
                ])
            ]
        )
    ]
)
