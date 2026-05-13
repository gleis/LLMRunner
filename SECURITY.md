# Security

LLMRunner is alpha software.

## Supported Versions

Only the latest commit on the main branch is currently supported.

## Localhost Only

LLMRunner is designed to bind to `127.0.0.1` by default. The server now binds to the configured host instead of listening on every interface.

If you change the host in `~/.llmrunner/config.json`, enable API key authentication and use firewalling and transport security appropriate for your environment. Do not expose LLMRunner directly to the public internet.

## API Keys

API key authentication is enabled when at least one key is configured.

The recommended local setup is an environment variable:

```sh
export LLMRUNNER_API_KEY="$(openssl rand -hex 32)"
llmrunner start
```

Clients can send either:

```text
Authorization: Bearer <key>
x-api-key: <key>
```

You can also store keys in `security.apiKeys` in `~/.llmrunner/config.json`, but environment variables are safer for shared config files.

Health checks at `/health` and `/v1/health` do not require authentication.

## Logs

Request logging is enabled by default. Logs include method, path, status, and duration. LLMRunner does not log request bodies, response bodies, API keys, or authorization headers.

HTTP request bodies are capped by `security.maxRequestBodyBytes`, which defaults to `10485760` bytes.

Use:

```sh
llmrunner logs
llmrunner logs --errors
llmrunner logs --follow
```

## Model Downloads

`llmrunner models pull` downloads GGUF files from Hugging Face or direct URLs. Only download and run models from sources you trust.

For private or gated Hugging Face models, LLMRunner reads `HF_TOKEN` from the environment and sends it to Hugging Face API and download endpoints.

## Reporting Issues

If you find a security issue, please open a GitHub security advisory or contact the maintainers privately before posting exploit details publicly.
