# LLMRunner API

LLMRunner exposes a local HTTP API that is compatible with OpenAI-style clients for common text and embedding workflows.

Default base URL:

```text
http://127.0.0.1:8080/v1
```

Authentication is optional. If no API key is configured, clients can use any non-empty API key. If `LLMRUNNER_API_KEY` or `security.apiKeys` is configured, all `/v1/*` endpoints require a matching key. `/health` and `/v1/health` stay unauthenticated for local service checks.

Accepted auth headers:

```text
Authorization: Bearer <key>
x-api-key: <key>
```

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/health` | Service health check. |
| `GET` | `/v1/health` | Versioned health check. |
| `GET` | `/v1/models` | Lists configured local models. |
| `GET` | `/v1/models/{model}` | Returns one configured local model. |
| `POST` | `/v1/chat/completions` | Starts the requested model if needed, then generates through the configured backend. Embedded mode supports normal and streaming responses. |
| `POST` | `/v1/completions` | Generates raw prompt completions. Embedded mode supports normal and streaming responses. |
| `POST` | `/v1/embeddings` | Computes embeddings. Embedded support depends on model compatibility. |

## Model Selection

LLMRunner reads the JSON `model` field for generation and embedding requests.

If `model` matches an entry in `~/.llmrunner/config.json`, that model is loaded. If the field is omitted, LLMRunner falls back to `defaultModel`, then the first configured model. If the field is present but does not match a configured model, LLMRunner returns a `404` `model_not_found` error.

Only one embedded model is kept active at a time. Requesting a different model unloads the current embedded model and loads the requested one. In server mode, LLMRunner stops the current `llama-server` process and starts a new one.

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

Get a single model:

```http
GET /v1/models/smollm2-135m
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

In embedded mode, LLMRunner returns an OpenAI-style response. In server mode, response shape is produced by `llama-server`.

For streaming, set:

```json
{
  "stream": true
}
```

The response uses server-sent events:

```text
data: {"id":"chatcmpl-...","object":"chat.completion.chunk","choices":[...]}

data: [DONE]
```

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

The embedded backend accepts a string `prompt` and returns an OpenAI-style text completion response.

For streaming, set:

```json
{
  "stream": true
}
```

The response uses server-sent events:

```text
data: {"id":"cmpl-...","object":"text_completion","choices":[...]}

data: [DONE]
```

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

Embedded mode computes embeddings through `libllama`. Embedding support depends on the selected model and backend configuration; many chat-tuned GGUFs can produce vectors, but dedicated embedding models are usually better.

## Errors

LLMRunner returns OpenAI-style JSON errors for routing, authentication, validation, model lookup, and startup failures. Invalid request bodies return `400`. Missing or invalid API keys return `401`. Missing models return `404`. Request bodies over `security.maxRequestBodyBytes` return `413`. Backend load/generation failures return `503`.

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

Authentication failure:

```json
{
  "error": {
    "message": "Missing or invalid API key.",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

## Client Setup

Use an OpenAI-compatible SDK with:

```text
base_url: http://127.0.0.1:8080/v1
api_key: local, or your configured API key if auth is enabled
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
