#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || "$1" != /* ]]; then
  echo "usage: $0 /absolute/path/to/herdr-cache-hit" >&2
  exit 2
fi

plugin_dir=${1%/}
wrapper="$plugin_dir/scripts/agy-statusline-capture.sh"
if [[ ! -x "$wrapper" ]]; then
  echo "Error: executable wrapper not found at $wrapper" >&2
  exit 1
fi

config_dir="${AGY_CLI_CONFIG_DIR:-$HOME/.gemini/antigravity-cli}"
statusline="$config_dir/statusline.sh"
backup="$config_dir/statusline.real.sh"
mkdir -p "$config_dir"

if [[ -L "$statusline" && "$(readlink "$statusline")" == "$wrapper" ]]; then
  echo "AGY statusline wrapper is already installed."
  exit 0
fi

if [[ -e "$backup" || -L "$backup" ]]; then
  echo "Error: refusing to overwrite existing backup $backup" >&2
  exit 1
fi

if [[ -e "$statusline" || -L "$statusline" ]]; then
  mv "$statusline" "$backup"
fi
ln -s "$wrapper" "$statusline"
echo "Installed AGY statusline wrapper at $statusline"
