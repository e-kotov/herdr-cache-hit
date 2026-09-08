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

> **Compatibility note:** The v0.1.0 decoder is covered by a schema-derived synthetic fixture, not a captured AGY payload. If AGY changes its private protobuf layout or the helper returns no data, use the tested statusline bridge below.

---

## Method 2: Live Statusline Bridge (Zero-Lag / Real-Time)

If you want instantaneous HUD updates while AGY is streaming turns—without waiting for generation records to commit to SQLite—you can bridge AGY's statusline callback to Herdr.

Use the supplied wrapper as the supported bridge implementation. Its installer preserves an existing regular file or symlink as `statusline.real.sh`, refuses to overwrite a backup, and is safe to run again after a successful installation.

```bash
# The clone path must be absolute.
/absolute/path/to/herdr-cache-hit/scripts/install-agy-statusline.sh \
  /absolute/path/to/herdr-cache-hit
```

The wrapper forwards every payload unchanged to the preserved statusline. If no prior statusline existed, it prints the original payload.

---

## What if I don't use AGY?

If you only use **Codex CLI**, **Claude Code**, or **OpenCode**:
- You **do not** need the Go helper.
- You **do not** need any statusline hooks or scripts.
- The plugin detects agent harnesses per-pane and will only query the relevant file stores for the agents you actually use.
