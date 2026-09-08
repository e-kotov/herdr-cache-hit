#!/usr/bin/env bash
# Antigravity CLI statusline wrapper for Herdr cache-hit plugin.
# Bridges live prompt cache telemetry to ~/.cache/herdr-cache-plugin/agy-statusline/
set -euo pipefail

payload=$(cat)
original="${AGY_STATUSLINE_SCRIPT:-$HOME/.gemini/antigravity-cli/statusline.real.sh}"

# Parse into a validated JSON object so empty strings stay distinct fields.
conv_id="" model="" input=0 read=0 write=0
parsed=$(jq -ce '
  def counter: if . == null then 0 elif type == "number" and . >= 0 and floor == . then . else error("invalid counter") end;
  (.conversation_id // .session_id // "") as $sid |
  (if (.model | type) == "object" then (.model.display_name // "") elif (.model | type) == "string" then .model else "" end) as $model |
  (.context_window.current_usage // {}) as $u |
  {
    session_id: ($sid | tostring | gsub("[\t\r\n]"; " ")),
    model: ($model | tostring | gsub("[\t\r\n]"; " ")),
    input: ($u.input_tokens | counter),
    read: ($u.cache_read_input_tokens | counter),
    write: ($u.cache_creation_input_tokens | counter)
  }
' <<<"$payload" 2>/dev/null || true)

if [[ -n "$parsed" ]]; then
  conv_id=$(jq -r '.session_id' <<<"$parsed")
  model=$(jq -r '.model' <<<"$parsed")
  input=$(jq -r '.input' <<<"$parsed")
  read=$(jq -r '.read' <<<"$parsed")
  write=$(jq -r '.write' <<<"$parsed")
fi

if [[ -n "${conv_id:-}" ]] && jq -e '.read > 0 or .write > 0' >/dev/null 2>&1 <<<"$parsed"; then
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
