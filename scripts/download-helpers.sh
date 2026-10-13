#!/usr/bin/env bash
set -euo pipefail

REPO="e-kotov/herdr-cache-hit"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="${HERDR_CACHE_BIN_DIR:-$PLUGIN_ROOT/bin}"
mkdir -p "$BIN_DIR"

os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]') || { echo "Failed to detect OS" >&2; exit 1; }
arch=$(uname -m 2>/dev/null) || { echo "Failed to detect architecture" >&2; exit 1; }

case "$os:$arch" in
  darwin:arm64)              name="agy-usage-darwin-arm64" ;;
  darwin:x86_64)            name="agy-usage-darwin-amd64" ;;
  linux:x86_64)             name="agy-usage-linux-amd64" ;;
  linux:aarch64|linux:arm64) name="agy-usage-linux-arm64" ;;
  mingw*:x86_64|msys*:x86_64) name="agy-usage-windows-amd64.exe" ;;
  *)
    echo "Unsupported platform: $os:$arch. Please build from source using 'go build ./cmd/agy-usage'." >&2
    exit 1
    ;;
esac

version="${HERDR_CACHE_HELPER_VERSION:-}"
if [[ -z "$version" && -f "$PLUGIN_ROOT/herdr-plugin.toml" ]]; then
  version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*["'\'']\([^"'\'']*\)["'\''].*/\1/p' "$PLUGIN_ROOT/herdr-plugin.toml" | head -n 1)
fi

if [[ -n "$version" ]]; then
  tag="v${version#v}"
  url="https://github.com/${REPO}/releases/download/${tag}/${name}"
else
  url="https://github.com/${REPO}/releases/latest/download/${name}"
fi

target="$BIN_DIR/$name"
tmp_target="$BIN_DIR/.${name}.tmp.$$"
checksum_file="$BIN_DIR/.checksums.tmp.$$"
cleanup_download() { rm -f "$tmp_target" "$checksum_file"; }
trap cleanup_download EXIT

download_file() {
  local source_url=$1 destination=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$source_url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$source_url"
  else
    echo "Neither curl nor wget found in PATH." >&2
    return 1
  fi
}

echo "Downloading $name from $url..."
if ! download_file "$url" "$tmp_target" || [[ ! -s "$tmp_target" ]]; then
  echo "Error: Failed to download $name from $url" >&2
  echo "Please check https://github.com/${REPO}/releases or build from source using './scripts/build-agy-usage.sh'." >&2
  exit 1
fi

# Print LENGTH bytes of FILE at OFFSET as lowercase hex without spaces.
hex_at() {
  od -An -tx1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n'
}

# Describe the helper in file(1)'s words for the formats accepted below, from
# its executable header. Used where file(1) is missing, as in a default Termux.
describe_executable() {
  local path=$1 lfanew offset
  case "$(hex_at "$path" 0 4)" in
    7f454c46)
      # 64-bit little-endian, executable or position-independent executable.
      [[ "$(hex_at "$path" 4 2)" == 0201 ]] || return 0
      case "$(hex_at "$path" 16 2)" in 0200|0300) ;; *) return 0 ;; esac
      case "$(hex_at "$path" 18 2)" in
        3e00) echo "ELF 64-bit LSB executable, x86-64" ;;
        b700) echo "ELF 64-bit LSB executable, ARM aarch64" ;;
      esac ;;
    cffaedfe)
      [[ "$(hex_at "$path" 12 4)" == 02000000 ]] || return 0
      case "$(hex_at "$path" 4 4)" in
        07000001) echo "Mach-O 64-bit executable x86_64" ;;
        0c000001) echo "Mach-O 64-bit executable arm64" ;;
      esac ;;
    4d5a*)
      lfanew=$(hex_at "$path" 60 4)
      [[ "$lfanew" =~ ^[0-9a-f]{8}$ ]] || return 0
      offset=$((16#${lfanew:6:2}${lfanew:4:2}${lfanew:2:2}${lfanew:0:2}))
      [[ "$(hex_at "$path" "$offset" 4)" == 50450000 ]] || return 0
      [[ "$(hex_at "$path" $((offset + 24)) 2)" == 0b02 ]] || return 0
      case "$(hex_at "$path" $((offset + 4)) 2)" in
        6486) echo "PE32+ executable x86-64" ;;
        64aa) echo "PE32+ executable Aarch64" ;;
      esac ;;
  esac
}

# Require exactly the executable format and architecture selected above.
if command -v file >/dev/null 2>&1; then
  file_type=$(file -b "$tmp_target" 2>/dev/null || true)
else
  file_type=$(describe_executable "$tmp_target")
fi
case "$os:$arch" in
  darwin:arm64) expected_pattern="Mach-O 64-bit executable arm64" ;;
  darwin:x86_64) expected_pattern="Mach-O 64-bit executable x86_64" ;;
  linux:x86_64) expected_pattern="ELF 64-bit*executable*x86-64" ;;
  linux:aarch64|linux:arm64) expected_pattern="ELF 64-bit*executable*ARM aarch64" ;;
  mingw*:x86_64|msys*:x86_64) expected_pattern="PE32+ executable*x86-64" ;;
esac
if [[ ! "$file_type" == $expected_pattern* ]]; then
  echo "Error: Downloaded file has the wrong format or architecture for $os:$arch (got: $file_type)" >&2
  exit 1
fi

# A release without a unique valid checksum entry is not installable.
checksum_url="${url%/*}/checksums.txt"
if ! download_file "$checksum_url" "$checksum_file" || [[ ! -s "$checksum_file" ]]; then
  echo "Error: checksums.txt is required for helper installation" >&2
  exit 1
fi

expected_sum=""; checksum_matches=0
while read -r sum listed extra; do
  listed=${listed#\*}
  if [[ -z "${extra:-}" && "$listed" == "$name" && "$sum" =~ ^[[:xdigit:]]{64}$ ]]; then
    expected_sum=$(printf '%s' "$sum" | tr '[:upper:]' '[:lower:]')
    checksum_matches=$((checksum_matches + 1))
  fi
done <"$checksum_file"
if (( checksum_matches != 1 )); then
  echo "Error: checksums.txt must contain exactly one valid SHA-256 entry for $name" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  actual_sum=$(shasum -a 256 "$tmp_target" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  actual_sum=$(sha256sum "$tmp_target" | awk '{print $1}')
else
  echo "Error: shasum or sha256sum is required" >&2
  exit 1
fi
actual_sum=$(printf '%s' "$actual_sum" | tr '[:upper:]' '[:lower:]')
if [[ "$actual_sum" != "$expected_sum" ]]; then
  echo "Error: SHA-256 checksum mismatch for $name" >&2
  exit 1
fi

chmod +x "$tmp_target"
echo "Checksum verified."

mv -f "$tmp_target" "$target"
cleanup_download
trap - EXIT
echo "Successfully installed $target"
