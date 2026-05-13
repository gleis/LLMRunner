# Release Notes

This project does not have a stable release process yet. Current builds should be treated as alpha developer previews.

## Build A Local Bundle

Install llama.cpp on the build machine:

```sh
brew install llama.cpp
```

Package:

```sh
scripts/package-macos.sh --llama-server "$(which llama-server)"
```

Output:

```text
dist/LLMRunner.app
dist/llmrunner
```

## Before Publishing A Release

Checklist:

- Run `swift build -c release`.
- Run `bash -n scripts/package-macos.sh`.
- Run `python3 -m py_compile examples/python_chatbot.py`.
- Build `dist/LLMRunner.app`.
- Start the packaged CLI with `dist/llmrunner start`.
- Pull or reuse a small GGUF model with `dist/llmrunner models pull tiny`.
- Verify `curl http://127.0.0.1:8080/v1/models`.
- Verify one chat completion.
- Verify one streaming chat completion with `"stream": true`.
- Verify one text completion.
- Verify one embeddings request.
- Verify `otool -L dist/LLMRunner.app/Contents/MacOS/llmrunner` points `libllama` and `libggml` at `@executable_path/../Resources/lib`.
- Verify `codesign --verify --deep --strict dist/LLMRunner.app`.
- Stop the service with `dist/llmrunner stop`.

## Notarization

The current package script uses ad-hoc signing. For public downloadable binaries, use a Developer ID certificate and Apple notarization before publishing.
