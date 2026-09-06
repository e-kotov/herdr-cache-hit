#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"; TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-cache-bench.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export CODEX_SESSIONS_DIR="$TMP/sessions"; mkdir -p "$CODEX_SESSIONS_DIR/2026/09/06"; f="$CODEX_SESSIONS_DIR/2026/09/06/rollout-bench.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"id":"bench"}}' >"$f"
for i in $(seq 1 100); do printf '%s\n' '{"type":"token_usage_record","timestamp":"2026-09-06T10:00:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":500},"model":"m","model_provider":"p"}}' >>"$f"; done
source "$ROOT/lib/core.sh"; source "$ROOT/lib/codex.sh"; start=$(date +%s%N)
for _ in $(seq 1 10); do latest_usage "$f" bench >/dev/null; done
end=$(date +%s%N); awk -v ns="$((end-start))" 'BEGIN { printf "benchmark: 10 recent-tail parses in %.3f ms\n", ns/1000000 }'
