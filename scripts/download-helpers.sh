#!/usr/bin/env bash
set -euo pipefail

REPO="e-kotov/herdr-cache-hit"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$PLUGIN_ROOT/bin"
mkdir -p "$BIN_DIR"

os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]') || { echo "Failed to detect OS" >&2; exit 1; }
arch=$(uname -m 2>/dev/null) || { echo "Failed to detect architecture" >&2; exit 1; }

case "$os:$arch" in
  darwin:arm64)              name="agy-usage-darwin-arm64" ;;
  darwin:x86_64)            name="agy-usage-darwin-amd64" ;;
  linux:x86_64)             name="agy-usage-linux-amd64" ;;
  linux:aarch64|linux:arm64) name="agy-usage-linux-arm64" ;;
  *)
    echo "Unsupported platform: $os:$arch. Please build from source using 'go build ./cmd/agy-usage'." >&2
    exit 1
    ;;
esac

url="https://github.com/${REPO}/releases/latest/download/${name}"
target="$BIN_DIR/$name"

echo "Downloading $name from $url..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "$target"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$target" "$url"
else
  echo "Neither curl nor wget found in PATH." >&2
  exit 1
fi

chmod +x "$target"
echo "Successfully installed $target"
