# Finding And Pulling Models

LLMRunner can find and pull public GGUF models from Hugging Face without requiring a direct file URL.

## Quick Start

Pull a tiny known-good model:

```sh
llmrunner models pull tiny
```

Search Hugging Face:

```sh
llmrunner models search qwen3
```

Search results include download/like counts, the number of GGUF files in each repo, and a recommended GGUF file when one can be selected automatically.

Pull a Hugging Face GGUF repo:

```sh
llmrunner models pull Qwen/Qwen3-0.6B-GGUF
```

Pull from a search phrase:

```sh
llmrunner models pull "smollm2 135m"
```

Prefer a quantization:

```sh
llmrunner models pull Qwen/Qwen3-0.6B-GGUF --quant Q4_K_M
```

Pull an exact file when you already know which GGUF you want:

```sh
llmrunner models pull Qwen/Qwen3-0.6B-GGUF --file qwen3-0.6b-q4_k_m.gguf
```

List GGUF files in a repo:

```sh
llmrunner models files unsloth/SmolLM2-135M-Instruct-GGUF
```

The recommended file is marked with `*`. File rows include the detected quantization and size when Hugging Face exposes file metadata.

Use a direct URL when needed:

```sh
llmrunner models pull my-model --url https://huggingface.co/owner/repo/resolve/main/model.gguf
```

## What Pull Does

`models pull` downloads the selected GGUF file into:

```text
~/.llmrunner/models/<model-id>/
```

Then it updates:

```text
~/.llmrunner/config.json
```

If no default model is set, the first pulled model becomes the default.

## Resolution Rules

`llmrunner models pull tiny`

Uses a built-in catalog alias.

`llmrunner models pull owner/repo`

Treats the argument as a Hugging Face repo ID and picks a GGUF file from that repo.

`llmrunner models pull "search terms"`

Searches Hugging Face for GGUF model repos, picks the highest-ranked result with a usable GGUF file, and downloads it.

`llmrunner models pull local-id --repo owner/repo`

Uses `local-id` in LLMRunner config while downloading from the specified repo.

`llmrunner models pull owner/repo --file model.gguf`

Downloads a specific GGUF file from the repo.

## Quantization Choice

If you do not pass `--quant`, LLMRunner prefers files in this order:

```text
Q4_K_M
Q5_K_M
Q4_K_S
Q4_0
Q8_0
first available .gguf
```

`Q4_K_M` is usually a good default for small local models because it keeps file size and memory use low while preserving decent quality.

## Private Or Gated Models

Set a Hugging Face token before searching or pulling:

```sh
export HF_TOKEN=hf_...
```

LLMRunner sends that token to Hugging Face API and download requests.

## Current Scope

LLMRunner pulls GGUF files. If a Hugging Face repo only has formats like Safetensors, LLMRunner cannot run it directly through `llama-server`; search for a GGUF variant instead.
