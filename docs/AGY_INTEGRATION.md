# Antigravity CLI (AGY) Integration Guide

This guide explains how the **cache-hit** Herdr plugin extracts prompt-cache telemetry from Google Antigravity CLI (AGY).

---

## Why AGY is Different

Unlike **Codex CLI** or **Claude Code**, which continuously write prompt-cache token usage directly to text transcript files (`~/.codex/sessions/*.jsonl` and `~/.claude/projects/*.jsonl`), AGY CLI's transcript logs only record conversation turns and tool execution outputs—they do **not** record token counts.

Instead, AGY's internal telemetry lives in two places:
1. The local SQLite database (`~/.gemini/antigravity-cli/conversations/<session_id>.db`), populated at generation boundaries.
2. The real-time statusline callback (`~/.gemini/antigravity-cli/statusline.sh`), which receives in-flight `.context_window.current_usage` JSON payloads on every event turn.

To support both seamless out-of-the-box usage and zero-latency real-time tracking, the plugin supports two integration methods.

---

## Method 1: Zero-Config Go Helper (Recommended)

The easiest method requires no configuration or modifications to your AGY setup.

Simply download the precompiled `agy-usage` helper binary for your platform:

```bash
cd ~/.config/herdr/plugins/cache-hit   # or your cloned plugin directory
./scripts/download-helpers.sh
```

*(Alternatively, if you have Go installed, compile it locally with `./scripts/build-agy-usage.sh`)*.

### How it works:
When Herdr detects an AGY pane, the plugin automatically calls:
```bash
bin/agy-usage-<os>-<arch> "$HOME/.gemini/antigravity-cli/conversations/<session_id>.db" "<session_id>"
```
This reads the latest generation metadata from the SQLite database and feeds exact input, cache read, and cache write tokens into Herdr.

---

## Method 2: Live Statusline Bridge (Zero-Lag / Real-Time)

If you want instantaneous HUD updates while AGY is streaming turns—without waiting for generation records to commit to SQLite—you can bridge AGY's statusline callback to Herdr.

### Option 2A: Add the Bridge Snippet to your existing `statusline.sh`

If you already have a custom statusline script at `~/.gemini/antigravity-cli/statusline.sh`, paste this snippet near the top:

```bash
# --- Herdr cache-hit bridge for AGY ---
payload=$(cat)
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
  state_dir="$HOME/.cache/herdr-cache-plugin/agy-statusline"
  mkdir -p "$state_dir" 2>/dev/null || true
  key=$(printf '%s' "$conv_id" | tr -c 'A-Za-z0-9_.-' '_')
  now=$(date +%s)
  deadline=$((now + 300))
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
# --- End Herdr bridge ---
```

### Option 2B: Use the provided wrapper script

If you don't have a custom `statusline.sh` or prefer not to edit it, you can point AGY to our wrapper script:

```bash
mkdir -p ~/.gemini/antigravity-cli
ln -sf "$(pwd)/scripts/agy-statusline-capture.sh" ~/.gemini/antigravity-cli/statusline.sh
```

---

## What if I don't use AGY?

If you only use **Codex CLI**, **Claude Code**, or **OpenCode**:
- You **do not** need the Go helper.
- You **do not** need any statusline hooks or scripts.
- The plugin detects agent harnesses per-pane and will only query the relevant file stores for the agents you actually use.
