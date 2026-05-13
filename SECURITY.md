# Security

LLMRunner is alpha software.

## Supported Versions

Only the latest commit on the main branch is currently supported.

## Localhost Only

LLMRunner is designed to bind to `127.0.0.1` by default. It does not implement API key enforcement yet. Do not expose it directly to a network interface or the public internet.

If you change the host in `~/.llmrunner/config.json`, you are responsible for adding authentication, firewalling, and transport security appropriate for your environment.

## Model Downloads

`llmrunner models pull` downloads GGUF files from Hugging Face or direct URLs. Only download and run models from sources you trust.

For private or gated Hugging Face models, LLMRunner reads `HF_TOKEN` from the environment and sends it to Hugging Face API and download endpoints.

## Reporting Issues

If you find a security issue, please open a GitHub security advisory or contact the maintainers privately before posting exploit details publicly.
