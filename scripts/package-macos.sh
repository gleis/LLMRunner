#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/LLMRunner.app"
LLAMA_SERVER_PATH=""
CODESIGN=1

usage() {
  cat <<USAGE
Usage: scripts/package-macos.sh [--llama-server /path/to/llama-server] [--no-codesign]

Builds dist/LLMRunner.app and places llama-server in Contents/Resources/bin.
If --llama-server is omitted, the script uses the first llama-server found on PATH.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --llama-server)
      LLAMA_SERVER_PATH="${2:-}"
      shift 2
      ;;
    --no-codesign)
      CODESIGN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$LLAMA_SERVER_PATH" ]]; then
  LLAMA_SERVER_PATH="$ROOT_DIR/.build/llama-install/bin/llama-server"
fi

if [[ -z "$LLAMA_SERVER_PATH" || ! -x "$LLAMA_SERVER_PATH" ]]; then
  echo "llama-server was not found or is not executable. Pass --llama-server /path/to/llama-server." >&2
  exit 1
fi

cd "$ROOT_DIR"
LLAMA_PREFIX="${LLMRUNNER_LLAMA_PREFIX:-$ROOT_DIR/.build/llama-install}"
if [[ ! -f "$LLAMA_PREFIX/lib/pkgconfig/llama.pc" ]]; then
  echo "Run scripts/bootstrap-llama.sh before packaging." >&2
  exit 1
fi
export PKG_CONFIG_PATH="$LLAMA_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LLMRUNNER_LIBRARY_PATH="$LLAMA_PREFIX/lib"
swift build -c release

rm -rf "$APP_PATH"
mkdir -p \
  "$APP_PATH/Contents/MacOS" \
  "$APP_PATH/Contents/Resources/bin" \
  "$APP_PATH/Contents/Resources/lib" \
  "$APP_PATH/Contents/Resources/libexec"

cp "$ROOT_DIR/.build/release/llmrunner" "$APP_PATH/Contents/MacOS/llmrunner"
cp "$LLAMA_SERVER_PATH" "$APP_PATH/Contents/Resources/bin/llama-server"
cp "$ROOT_DIR/config.example.json" "$APP_PATH/Contents/Resources/config.example.json"

cp -R "$LLAMA_PREFIX"/lib/*.dylib "$APP_PATH/Contents/Resources/lib/"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>llmrunner</string>
  <key>CFBundleIdentifier</key>
  <string>com.llmrunner.service</string>
  <key>CFBundleName</key>
  <string>LLMRunner</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSBackgroundOnly</key>
  <true/>
</dict>
</plist>
PLIST

cat > "$DIST_DIR/llmrunner" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/LLMRunner.app/Contents/MacOS/llmrunner" "$@"
SH
chmod +x "$DIST_DIR/llmrunner"

# Libraries use @rpath; make every shipped binary independently relocatable.
install_name_tool -delete_rpath "$LLAMA_PREFIX/lib" "$APP_PATH/Contents/MacOS/llmrunner"
while IFS= read -r dylib; do
  install_name_tool -add_rpath @loader_path "$dylib"
done < <(find "$APP_PATH/Contents/Resources/lib" -type f -name '*.dylib')
install_name_tool -add_rpath @executable_path/../lib "$APP_PATH/Contents/Resources/bin/llama-server"

if [[ "$CODESIGN" -eq 1 ]] && command -v codesign >/dev/null 2>&1; then
  while IFS= read -r binary; do
    codesign --force --sign - "$binary"
  done < <(find "$APP_PATH/Contents" -type f \( -name 'llmrunner' -o -name 'llama-server' -o -name '*.dylib' -o -name '*.so' \))

  codesign --force --deep --sign - "$APP_PATH"
fi

echo "Built $APP_PATH"
echo "CLI wrapper: $DIST_DIR/llmrunner"
