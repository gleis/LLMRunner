#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REV=cd959bae99ff4bed22bef2604f45241c09bbb8c8 # upstream v0.9.0
SOURCE="$ROOT/.build/llama-source"
PREFIX="$ROOT/.build/llama-install"
if [[ ! -d "$SOURCE/.git" ]]; then
  mkdir -p "$SOURCE"
  git -C "$SOURCE" init
  git -C "$SOURCE" remote add origin https://github.com/ggml-org/llama.cpp.git
fi
git -C "$SOURCE" fetch --depth 1 origin "$REV"
git -C "$SOURCE" checkout --detach "$REV"
cmake -S "$SOURCE" -B "$SOURCE/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DGGML_NATIVE=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON
cmake --build "$SOURCE/build" --config Release -j 4
rm -rf "$PREFIX"
cmake --install "$SOURCE/build"
printf 'Build with PKG_CONFIG_PATH=%s/lib/pkgconfig swift test\n' "$PREFIX"
