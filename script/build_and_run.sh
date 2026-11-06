#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PKG_CONFIG_PATH="$ROOT/.build/llama-install/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LLMRUNNER_LIBRARY_PATH="$ROOT/.build/llama-install/lib"
MODE="${1:-run}"
swift build
BINARY="$(swift build --show-bin-path)/llmrunner"
case "$MODE" in
  --build-only) exit 0 ;;
  --debug) exec lldb -- "$BINARY" ;;
  --verify) exec "$BINARY" help ;;
  --logs|--telemetry) exec "$BINARY" logs --follow ;;
  *) exec "$BINARY" serve ;;
esac
