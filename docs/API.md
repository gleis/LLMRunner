# LLMRunner API

LLMRunner exposes a local HTTP API that is compatible with OpenAI-style clients for common text and embedding workflows.

Default base URL:

```text
http://127.0.0.1:8080/v1
```

Authentication is not enforced yet. If a client requires an API key, use any non-empty string.

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/health` | Service health check. |
| `GET` | `/v1/health` | Versioned health check. |
| `GET` | `/v1/models` | Lists configured local models. |
| `POST` | `/v1/chat/completions` | Starts the requested model if needed, then proxies to `llama-server`. |
| `POST` | `/v1/completions` | Starts the requested model if needed, then proxies to `llama-server`. |
| `POST` | `/v1/embeddings` | Starts the requested model if needed, then proxies to `llama-server`. |

## Model Selection

For proxied requests, LLMRunner reads the JSON `model` field.

If `model` matches an entry in `~/.llmrunner/config.json`, that model is loaded. If the field is omitted or unknown, LLMRunner falls back to `defaultModel`, then the first configured model.

Only one backend model process is kept active at a time. Requesting a different model stops the current `llama-server` process and starts a new one.

## Health

```http
GET /health
```

Example:

```sh
curl http://127.0.0.1:8080/health
```

Response:

```json
{
  "status": "ok"
}
```

## List Models

```http
GET /v1/models
```

Example:

```sh
curl http://127.0.0.1:8080/v1/models
```

Response:

```json
{
  "object": "list",
  "data": [
    {
      "id": "smollm2-135m",
      "object": "model",
      "created": 0,
      "owned_by": "llmrunner"
    }
  ]
}
```

## Chat Completions

```http
POST /v1/chat/completions
```

Example:

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "smollm2-135m",
    "messages": [
      { "role": "user", "content": "Say ready in one short sentence." }
    ],
    "max_tokens": 24,
    "temperature": 0
  }'
```

LLMRunner forwards the request body to the active backend. Response shape is produced by `llama-server`, for example:

```json
{
  "id": "chatcmpl-example",
  "object": "chat.completion",
  "model": "SmolLM2-135M-Instruct.Q4_K_M.gguf",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "I'm ready to help."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 37,
    "completion_tokens": 5,
    "total_tokens": 42
  }
}
```

## Text Completions

```http
POST /v1/completions
```

Example:

```sh
curl http://127.0.0.1:8080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "smollm2-135m",
    "prompt": "Local inference is",
    "max_tokens": 32,
    "temperature": 0.2
  }'
```

The request and response are proxied to `llama-server`.

## Embeddings

```http
POST /v1/embeddings
```

Example:

```sh
curl http://127.0.0.1:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "smollm2-135m",
    "input": "A short sentence to embed."
  }'
```

The request and response are proxied to `llama-server`. Embedding support depends on the selected model and backend configuration.

## Errors

LLMRunner returns OpenAI-style JSON errors for routing and startup failures.

Unknown route:

```json
{
  "error": {
    "message": "No route for GET /missing",
    "type": "invalid_request_error"
  }
}
```

Backend startup failure:

```json
{
  "error": {
    "message": "The model backend did not become ready before the startup timeout.",
    "type": "server_error"
  }
}
```

## Client Setup

Use an OpenAI-compatible SDK with:

```text
base_url: http://127.0.0.1:8080/v1
api_key: any non-empty string
```

Python example:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8080/v1",
    api_key="local"
)

response = client.chat.completions.create(
    model="smollm2-135m",
    messages=[{"role": "user", "content": "Say ready."}],
    max_tokens=24,
)

print(response.choices[0].message.content)
```
