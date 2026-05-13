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
        .executableTarget(
            name: "LLMRunner"
        )
    ]
)
