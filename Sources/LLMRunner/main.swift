import Foundation

do {
    try await CLI.run(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("llmrunner failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
