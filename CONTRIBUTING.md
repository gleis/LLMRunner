# Contributing

Thanks for checking out LLMRunner. This project is currently alpha software, so small focused issues and pull requests are easiest to review.

## Development Setup

Requirements:

- macOS
- Xcode command line tools or Xcode
- Swift 6 or newer
- Python 3 for the example chatbot
- `llama.cpp` from Homebrew if you want to run or package local inference

Build:

```sh
swift build
```

Build release:

```sh
swift build -c release
```

Run syntax checks:

```sh
bash -n scripts/package-macos.sh
python3 -m py_compile examples/python_chatbot.py
```

## Local Runtime

By default, LLMRunner writes runtime state to:

```text
~/.llmrunner
```

For tests, use an isolated directory:

```sh
export LLMRUNNER_HOME=/tmp/llmrunner-dev
```

## Pull Requests

Please keep changes scoped. Good PRs usually include:

- A short explanation of the behavior change.
- Build or smoke-test commands you ran.
- Documentation updates for user-facing CLI/API changes.

Avoid committing build products, downloaded models, `dist/`, or runtime state.
