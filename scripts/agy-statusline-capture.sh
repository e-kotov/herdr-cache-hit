#!/usr/bin/env bash
set -u

capture_dir="${AGY_STATUS_CAPTURE_DIR:-${TMPDIR:-/tmp}/agy-status-capture}"
original="${AGY_STATUSLINE_SCRIPT:-$HOME/.gemini/antigravity-cli/statusline.sh}"
mkdir -p "$capture_dir" 2>/dev/null || true

payload=$(cat)
session_id=$(jq -r '.session_id // .conversation_id // "unknown"' <<<"$payload" 2>/dev/null || printf 'unknown')
stamp=$(date +%s)
printf '%s\n' "$payload" >"$capture_dir/${session_id}.${stamp}.json" 2>/dev/null || true

exec "$original" <<<"$payload"
