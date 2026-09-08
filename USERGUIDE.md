# User Guide & Configuration Manual

This guide covers full configuration, token customization, sidebar styling, and declarative view sorting for the **cache-hit** Herdr plugin.

---

## Table of Contents

1. [Architecture & How It Works](#architecture--how-it-works)
2. [Configuration Reference](#configuration-reference)
3. [Token Reference](#token-reference)
4. [Sidebar Styling & Color Rules](#sidebar-styling--color-rules)
5. [Agent Sorting & Keybindings](#agent-sorting--keybindings)
6. [Agent Adapters & Data Sources](#agent-adapters--data-sources)
7. [Troubleshooting & Diagnostics](#troubleshooting--diagnostics)

---

## Architecture & How It Works

`cache-hit` is an event-driven, one-shot metadata scanner for [Herdr](https://github.com/herdrdev/herdr).
- **No Background Daemon**: Unlike polling daemons, `watch.sh` executes only when Herdr triggers an event (agent detection, status change, focus, pane close/exit).
- **Self-Contained Expiration Timer**: When a pane has an active cache, a lightweight background sleep process (`schedule_wake`) is scheduled to wake Herdr at the exact expiration threshold (e.g. 5 minutes before expiry or at expiry) to transition the UI seamlessly without requiring continuous polling.
- **Privacy**: Prompts, tool inputs, and message bodies are never read or transmitted. Only token usage counters and session identifiers are inspected.

---

## Configuration Reference

Configuration is stored in `config.json` inside the plugin's configuration directory:

```bash
herdr plugin config-dir cache-hit
```

If `config.json` does not exist, safe built-in defaults are used. Changes to `config.json` take effect on the very next Herdr scan without needing a server restart.

### Global Settings

| Setting | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `hot_symbol` | string | `""` | Symbol or emoji prepended to the countdown clock when the cache is active and healthy (> `expiring_threshold_seconds`). E.g. `"♨️"` or `""`. |
| `expiring_symbol` | string | `"⏰"` | Symbol or emoji prepended when remaining cache lifetime is less than or equal to `expiring_threshold_seconds`. E.g. `"⏰"` or `"⚠️"`. |
| `cold_symbol` | string | `""` | Symbol prepended when the cache has expired. E.g. `"❄"` or `""`. |
| `expiring_threshold_seconds`| integer | `300` | Warning threshold in seconds (default 5 minutes). At or below this, the warning symbol appears. |
| `bold_time` | boolean | `true` | When `true`, converts countdown clock digits into Unicode mathematical sans-serif bold characters (`𝟬-𝟵`) for visual punch. |
| `bold_threshold_seconds` | integer | `300` | Countdown threshold in seconds under which clock digits turn bold. Keeps healthy caches sleek and non-bold, turning bold only when expiring. |
| `timezone` | string | `""` | IANA timezone name (e.g. `"Europe/Berlin"`, `"America/New_York"`). When empty, respects `HERDR_PLUGIN_TIMEZONE` or the local system timezone. |

### Per-Agent Settings

Supported agent keys: `agy` (Antigravity CLI), `claude` (Claude Code), `codex` (Codex CLI), `opencode` (OpenCode).

```json
{
  "agy": {
    "enabled": true,
    "show_deadline": true,
    "show_read_tokens": true,
    "show_write_tokens": false,
    "show_percentage": false,
    "show_model": false,
    "ttl_ceiling": 3600
  }
}
```

| Field | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | boolean | `true` | Enable cache tracking for this agent. Set `false` to clear this agent's cache token. |
| `show_deadline` | boolean | `true` | Include the estimated expiration countdown time (`~15:44`). |
| `show_read_tokens` | boolean | `true` | Include read/cached tokens counter (e.g. `⇣95.4k`). |
| `show_write_tokens`| boolean | `false` | Include cache-creation tokens counter (e.g. `⇡12.3k`). |
| `show_percentage` | boolean | Agent-dependent | Show cache hit percentage (`99%`). Defaults `true` for Codex/OpenCode, `false` for AGY/Claude. |
| `show_model` | boolean | `false` | Include model name in the token string. |
| `ttl_ceiling` | integer | `3600` | Hard upper bound in seconds on learned prompt-cache survival time. |

---

## Token Reference

The plugin emits the following pane tokens to Herdr:

| Token | Description | Example Output |
| :--- | :--- | :--- |
| **`$cache`** | **Unified string** combining status, countdown, percentage, and token counts without middle-dot separators. | Hot: `~15:44 99% ⇣95.4k`<br>Expiring: `⏰~𝟭𝟱:𝟰𝟰 99% ⇣95.4k`<br>Cold: `99% ⇣95.4k` |
| **`$cache_status`** | Just the status symbol and countdown clock (empty when cold). | `~15:44` or `⏰~𝟭𝟱:𝟰𝟰` |
| **`$cache_pct`** | Just the cache hit percentage. | `99%` |
| **`$cache_tokens`** | Just the read/write token counters. | `⇣95.4k` |
| **`$cache_state`** | Lifecycle state identifier. | `hot`, `expiring`, or `cold` |
| **`cache_deadline`**| Unix epoch integer timestamp of expiration. | `1788877732` (cleared when cold) |

---

## Sidebar Styling & Color Rules

Herdr's sidebar configuration (`~/.config/herdr/config.toml`) controls how tokens are rendered. Using conditional `rules` on `$cache` allows dynamic color transitions:

```toml
[ui.sidebar.agents]
rows = [
  [
    { token = "state_icon", bold = true, dim = false },
    { token = "agent", fg = "#241835", bold = true, dim = false }
  ],
  [
    { token = "$cache", fg = "#64748b", bold = false, dim = true, rules = [
      { starts_with = "⏰", bold = true, dim = false, fg = "#7f1d1d" }, # Urgent red
      { starts_with = "⚠️", bold = true, dim = false, fg = "#b45309" }, # Warning amber
      { starts_with = "~", bold = false, dim = false, fg = "#713f78" },  # Active magenta
      { starts_with = "♨️", bold = false, dim = false, fg = "#713f78" }  # Active hot
    ] }
  ],
  [
    { token = "workspace", fg = "#4c4669", bold = false, dim = false },
    { token = "tab", fg = "#4c4669", bold = false, dim = false }
  ]
]
```

---

## Agent Sorting & Keybindings

The plugin includes `bin/herdr-cache-view`, a declarative view manager that interfaces with Herdr's JSON-RPC socket API (`agent.view.set` and `agent.view.clear`).

### View Modes
1. **`expiry`**: Sorts active sessions with live prompt caches by earliest expiration deadline first (`cache_deadline asc`), keeping expiring sessions at the top. Cold sessions fall back cleanly to Herdr priority mode (`attention desc`, `state_change_seq desc`).
2. **`native`**: Herdr's default interactive sort mode.

### CLI Usage

```bash
# Toggle between expiry sorting and native sorting
herdr-cache-view toggle

# Explicitly set view
herdr-cache-view set expiry
herdr-cache-view set native

# Check current active mode
herdr-cache-view get

# Restore saved mode (run on startup)
herdr-cache-view restore
```

### Herdr Keybinding Integration

Add a keybinding in `~/.config/herdr/config.toml` to toggle cache sorting with `prefix+s`:

```toml
[[keys.command]]
key = "s"
command = ["bash", "-c", "herdr-cache-view toggle"]

# Remap Herdr settings to prefix+S (shift+s)
[keys]
settings = "S"
```

The active mode is saved in `sort_mode.json` and automatically restored whenever Herdr boots via the plugin's `[[startup]]` hook.

---

## Agent Adapters & Data Sources

| Agent | Extraction Method | Required Helper / Dependencies |
| :--- | :--- | :--- |
| **Codex CLI** | Rollout inspection from `~/.codex/sessions` | None (pure `bash` + `jq`) |
| **Claude Code** | Project transcript analysis (`~/.claude/projects/`) | None (pure `bash` + `jq`) |
| **OpenCode** | SQLite database (`~/.local/share/opencode/opencode.db`) | `python3` |
| **AGY / Antigravity CLI** | Multi-tier fallback (Statusline → Go helper → Transcript) | Optional Go helper (`agy-usage-*`) or statusline hook |

### AGY / Antigravity CLI Architecture

Because AGY CLI transcripts do not serialize token metrics to disk, the plugin uses a 3-tier fallback strategy:
1. **Tier 1 — Live Statusline Sidecar (Fastest, Zero Polling)**: If you use the optional statusline export script (`scripts/agy-statusline-capture.sh` or equivalent in your `statusline.sh`), real-time prompt cache stats are written to `~/.cache/herdr-cache-plugin/agy-statusline/<sid>.json`. This gives instantaneous HUD updates with zero SQLite parsing.
2. **Tier 2 — Go SQLite Helper (`agy-usage-*`)**: If the statusline sidecar is absent, the plugin invokes the compiled helper to extract token metrics directly from AGY's internal SQLite database (`~/.gemini/antigravity-cli/conversations/<sid>.db`). Precompiled binaries are provided for macOS and Linux.
3. **Tier 3 — Transcript Fallback**: If neither is available, it attempts to read `transcript.jsonl` (used by AGY Web IDE).

> [!NOTE]
> **If you don't use AGY CLI:**
> You do **not** need the Go helper or any statusline scripts. Codex, Claude Code, and OpenCode work completely out of the box with standard system tools (`bash`, `jq`, and optionally `python3`).

---

## Troubleshooting & Diagnostics

### Inspect Live Tokens
Run `herdr pane list` to view the tokens currently assigned to each pane:
```bash
herdr pane list | jq '.result.panes[] | {agent, tokens}'
```

### Inspect Observations
Survival observations are stored in:
```bash
cat ~/.local/share/herdr/plugins/cache-hit/observations.json
```

### Verify Scripts & Tests
```bash
bash -n watch.sh
shellcheck watch.sh lib/*.sh bin/herdr-cache-view scripts/*.sh
bash tests/test_watch.sh
```
