# Third-Party Notices

LLMRunner can package third-party runtime components into `dist/LLMRunner.app`.

## llama.cpp

The bundled `libllama` dynamic libraries and optional `llama-server` binary come from llama.cpp when you run:

```sh
scripts/package-macos.sh --llama-server /path/to/llama-server
```

llama.cpp is a separate project with its own license and notices:

```text
https://github.com/ggml-org/llama.cpp
```

## ggml

Homebrew builds of `llama-server` may depend on ggml dynamic libraries. The package script copies required `libggml*.dylib` files into the app bundle when available through Homebrew.

ggml is a separate project with its own license and notices:

```text
https://github.com/ggml-org/ggml
```

## Models

Downloaded model files are not part of this repository. Model licenses vary by publisher. Check the Hugging Face model card before redistributing or using a model commercially.

Pinned source build: llama.cpp v0.9.0 (`cd959bae99ff4bed22bef2604f45241c09bbb8c8`), including its matching ggml tree, https://github.com/ggml-org/llama.cpp (MIT).
