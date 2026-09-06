#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
mkdir -p "$root/bin"
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$root/bin/agy-usage-darwin-arm64" "$root/cmd/agy-usage"
