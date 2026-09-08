#!/usr/bin/env bash
# Antigravity CLI statusline wrapper for Herdr cache-hit plugin.
# Bridges live prompt cache telemetry to ~/.cache/herdr-cache-plugin/agy-statusline/
set -euo pipefail

payload=$(cat)
original="${AGY_STATUSLINE_SCRIPT:-$HOME/.gemini/antigravity-cli/statusline.real.sh}"

# Extract conversation ID and prompt cache metrics
conv_id="" model="Gemini" input=0 read=0 write=0
eval "$(jq -r '
  (.conversation_id // .session_id // "") as $sid |
  (.model.display_name // .model // "Gemini") as $model |
  (.context_window.current_usage // {}) as $u |
  ($u.input_tokens // 0) as $input |
  ($u.cache_read_input_tokens // 0) as $read |
  ($u.cache_creation_input_tokens // 0) as $write |
  "conv_id=\($sid | @sh); model=\($model | @sh); input=\($input); read=\($read); write=\($write);"
' <<<"$payload" 2>/dev/null || true)"

if [[ -n "${conv_id:-}" ]] && (( read + write > 0 )); then
  state_dir="${AGY_STATUSLINE_STATE_DIR:-$HOME/.cache/herdr-cache-plugin/agy-statusline}"
  mkdir -p "$state_dir" 2>/dev/null || true
  key=$(printf '%s' "$conv_id" | tr -c 'A-Za-z0-9_.-' '_')
  now=$(date +%s)
  deadline=$((now + 300)) # Default 300s TTL for Gemini prompt prefix cache
  tmp="$state_dir/$key.json.$$"
  if jq -n \
    --arg sid "$conv_id" --arg model "$model" --arg provider "antigravity" \
    --argjson observed "$now" --argjson deadline "$deadline" \
    --argjson input "$input" --argjson read "$read" --argjson write "$write" \
    '{session_id:$sid,observed_at:$observed,input_tokens:$input,cache_read_tokens:$read,cache_creation_tokens:$write,model:$model,provider:$provider,deadline:$deadline}' \
    >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state_dir/$key.json" 2>/dev/null || rm -f "$tmp"
  fi
fi

# Pass through to original statusline script if present
if [[ -x "$original" ]]; then
  exec "$original" <<<"$payload"
else
  printf '%s\n' "$payload"
fi
