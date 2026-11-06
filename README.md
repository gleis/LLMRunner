# LLMRunner

LLMRunner is a no-GUI macOS service that exposes an OpenAI-compatible HTTP API for local GGUF models. It can run models in-process through embedded `libllama`, or proxy to `llama-server` as a fallback backend.

> Alpha status: LLMRunner is useful today for local development and experiments, but it is not yet a polished consumer installer. The API binds to localhost by default. Anonymous access is available on loopback; a configured API key is required for every non-loopback bind.

It is intentionally small:

- `GET /v1/models` lists configured local models.
- `POST /v1/chat/completions` starts the requested model if needed and generates with embedded `libllama` by default, including OpenAI-style streaming.
- `POST /v1/completions` generates raw prompt completions with embedded `libllama`.
- `POST /v1/embeddings` computes embeddings with embedded `libllama`.
- `GET /health` returns service health.

The default inference engine is embedded `libllama` from llama.cpp. LLMRunner owns model selection, model loading, and the stable OpenAI-compatible front door.

## Quickstart

Install the backend on your build machine:

```sh
brew install cmake pkg-config
scripts/bootstrap-llama.sh
```

Build and package:

```sh
PKG_CONFIG_PATH="$PWD/.build/llama-install/lib/pkgconfig" swift build -c release
scripts/package-macos.sh
```

Pull a tiny model and start the service:

```sh
dist/llmrunner models pull tiny
dist/llmrunner start
dist/llmrunner status
```

Test the OpenAI-compatible API:

```sh
curl http://127.0.0.1:8080/v1/models
```

Try the example chatbot:

```sh
python3 examples/python_chatbot.py --model smollm2-135m
```

## Backends

LLMRunner supports two backend modes:

```json
{
  "backend": {
    "mode": "embedded"
  }
}
```

`embedded` is the default and runs chat completions, text completions, and embeddings in-process through `libllama`.

```json
{
  "backend": {
    "mode": "server"
  }
}
```

`server` starts and proxies to `llama-server`. Use this as a compatibility fallback if a model or route behaves better through `llama-server`.

In server mode, LLMRunner looks for `backend.executable` in a bundle-friendly order:

1. `LLMRunner.app/Contents/Resources/llama-server`
2. `LLMRunner.app/Contents/Resources/bin/llama-server`
3. next to the `llmrunner` executable
4. the current working directory
5. `PATH`

For development, the quickest backend install is:

```sh
brew install cmake pkg-config
scripts/bootstrap-llama.sh
```

For distribution, the package script bundles `libllama`, `ggml`, ggml backend plugins, and `llama-server`.

## Configure

Create a config:

```sh
mkdir -p ~/.llmrunner
cp config.example.json ~/.llmrunner/config.json
```

Then pull a model:

```sh
llmrunner models pull tiny
```

## Run

```sh
swift run llmrunner serve --config ~/.llmrunner/config.json
```

Use it with OpenAI-style clients:

```sh
curl http://127.0.0.1:8080/v1/models
```

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "local-default",
    "messages": [
      { "role": "user", "content": "Write a haiku about local inference." }
    ]
  }'
```

Point SDKs at:

```text
base_url: http://127.0.0.1:8080/v1
api_key: local, or your configured API key if auth is enabled
```

Full HTTP API documentation is in [docs/API.md](docs/API.md).

Security notes are in [SECURITY.md](SECURITY.md).

## CLI

The same binary manages the background service and local model library:

```sh
llmrunner start
llmrunner status
llmrunner logs
llmrunner stop
```

Model commands:

```sh
llmrunner models list
llmrunner models search qwen3
llmrunner models files Qwen/Qwen3-0.6B-GGUF
llmrunner models pull tiny
llmrunner models pull Qwen/Qwen3-0.6B-GGUF --quant Q4_K_M
llmrunner models pull Qwen/Qwen3-0.6B-GGUF --file qwen3-0.6b-q4_k_m.gguf
llmrunner models pull "smollm2 135m"
llmrunner models delete qwen3-8b
```

`models search` and `models files` show GGUF counts, recommended files, quantization hints, and file sizes when Hugging Face exposes them. `models pull` can use built-in aliases, Hugging Face repo IDs, search phrases, specific GGUF filenames, or direct URLs. It downloads the selected GGUF file into `~/.llmrunner/models/<model-id>/`, adds it to `~/.llmrunner/config.json`, and makes it the default model if there is no default yet.

Model search and pull details are in [docs/MODELS.md](docs/MODELS.md).

For isolated tests or portable installs, set:

```sh
export LLMRUNNER_HOME=/path/to/runtime-directory
```

## Security And Logging

LLMRunner binds to `127.0.0.1` by default. To require an API key, set an environment variable before starting:

```sh
export LLMRUNNER_API_KEY="$(openssl rand -hex 32)"
llmrunner start
```

Clients can send either:

```text
Authorization: Bearer <key>
x-api-key: <key>
```

You can also store keys in `security.apiKeys` in `~/.llmrunner/config.json`. Request logging is enabled by default and writes method, path, status, and duration without request bodies or authorization headers.

Requests are capped at `security.maxRequestBodyBytes`, which defaults to `10485760` bytes.

```sh
llmrunner logs --lines 50
llmrunner logs --follow
llmrunner logs --errors
```

## Test Chatbot

There is a small dependency-free Python chatbot in `examples/python_chatbot.py`:

```sh
python3 examples/python_chatbot.py --model smollm2-135m
```

It talks to `http://127.0.0.1:8080/v1` and keeps conversation history in memory until you type `/quit`.

## Build A Bundle

If `llama-server` is already on PATH:

```sh
scripts/package-macos.sh
```

Or pass a specific binary:

```sh
scripts/package-macos.sh --llama-server /path/to/llama-server
```

This creates:

```text
dist/LLMRunner.app
```

The app bundle contains:

- `Contents/MacOS/llmrunner`
- `Contents/Resources/bin/llama-server`
- `Contents/Resources/lib/libllama*.dylib`
- `Contents/Resources/lib/libggml*.dylib`
- `Contents/Resources/libexec/libggml*.so`
- `Contents/Resources/config.example.json`

The package script also creates a convenience CLI wrapper at:

```text
dist/llmrunner
```

The bundle is ad-hoc signed by default. Use `--no-codesign` to skip that during local experiments.

Release packaging notes are in [docs/RELEASES.md](docs/RELEASES.md).

## Run On Login With launchd

Build the bundle, copy `dist/LLMRunner.app` to `/Applications`, then copy `LaunchAgents/com.llmrunner.service.plist.example` to `~/Library/LaunchAgents/com.llmrunner.service.plist`.

Update `/Users/YOU/.llmrunner/config.json` in the plist, then load it:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.llmrunner.service.plist
launchctl enable gui/$(id -u)/com.llmrunner.service
```

## Notes

Only one model process is kept active at a time. If a request asks for a different configured model, LLMRunner stops the current backend and starts the requested one.

## Current Limitations

- macOS only.
- GGUF models only.
- Loopback access can be anonymous. Non-loopback binding fails without a configured API key.
- Embedded chat streaming is supported for `/v1/chat/completions`.
- Embedded completion streaming is supported for `/v1/completions`.
- Embedded embeddings depend on model compatibility; not every GGUF model is a good embedding model.
- One active embedded model at a time.
- Public binary releases still need Developer ID signing and notarization.
- The package script requires the pinned source build from `scripts/bootstrap-llama.sh`.

## License

MIT. See [LICENSE](LICENSE).

## Reproducible native dependency

Install CMake and pkg-config, then run `scripts/bootstrap-llama.sh`. It builds llama.cpp v0.9.0 at commit `cd959bae99ff4bed22bef2604f45241c09bbb8c8`, including its matching ggml libraries, for macOS 14+. Build/test with `PKG_CONFIG_PATH="$PWD/.build/llama-install/lib/pkgconfig" swift test`. `scripts/package-macos.sh` packages the pinned libraries and server; it no longer installs or bundles an unpinned Homebrew llama.cpp. The source commit had no OSV matches on 2026-11-06; rerun dependency checks before future releases.

The Codex Run action uses `script/build_and_run.sh`. `--build-only` verifies a build without launching the service. Source builds discover headers/libraries through pkg-config. `LLMRUNNER_LIBRARY_PATH` overrides the runtime library directory for custom builds.

## Endpoint scopes and limits

Optional `security.keyScopes` maps an exact configured API key to allowed endpoint paths, for example `{ "your-key": ["/v1/models", "/v1/embeddings"] }`. Keys omitted from this map retain full access; an empty list denies all authenticated API routes. Scope keys must match the trimmed configured keys exactly. `security.requestsPerMinute` defaults to 120 per key (one shared bucket for anonymous loopback clients). Exhaustion returns 429 and `Retry-After: 60`. Health GETs remain public and exempt. Both embedded and managed-server inference use these controls. The unauthenticated managed llama-server is restricted to loopback and rejects `--host` overrides.

The current local package is ad-hoc signed. Developer ID signing, notarization, and a signed public release remain separate distribution requirements.

After package verification, `scripts/sign-notarize.sh dist/LLMRunner.app` creates and validates a notarized DMG when `DEVELOPER_ID_APPLICATION` and `NOTARYTOOL_PROFILE` are configured.
