# Herdr Agent Cache HUD

`cache-hit` is a macOS and Linux Herdr plugin that reports per-conversation cache usage
for Codex, AGY (`agy`/Antigravity CLI), Claude, and OpenCode as the `cache` pane token.
It reads local rollout/transcript metadata; prompt contents are never
transmitted. AGY prefers the live statusline sidecar written by the
chezmoi-managed `~/.gemini/antigravity-cli/statusline.sh`, then the packaged
native Go decoder for its read-only SQLite conversation database, and finally
transcript parsing. The sidecar is keyed by AGY conversation ID, so multiple
AGY panes can run in parallel without sharing cache state.

## Install and remove

```bash
cd /Users/ek/home/sync/personal/code_repository/pet_projects/harness-plugins
bash -n herdr-cache-plugin/watch.sh
shellcheck herdr-cache-plugin/watch.sh herdr-cache-plugin/lib/*.sh
herdr plugin unlink cache-hit 2>/dev/null || true
herdr plugin link "$PWD/herdr-cache-plugin"
herdr plugin list
```

Remove it with `herdr plugin unlink cache-hit`. Herdr invokes the
lock-protected one-shot scanner on startup, handoff, and supported pane
lifecycle/status events; no background process is left running.

## Configuration

Configuration is optional and is read on every scan. Get the stable per-plugin
directory with:

```bash
herdr plugin config-dir cache-hit
```

Copy [`config.example.json`](config.example.json) there as `config.json` and
edit settings. Top-level settings include `hot_symbol` (default `""`),
`expiring_symbol` (default `"⏰"`), `cold_symbol` (default `""`),
`expiring_threshold_seconds` (default `300` / 5 minutes), `bold_time` (default `true`),
`bold_threshold_seconds` (default `300`, bolding digits when under threshold),
and `timezone` (e.g. `"Europe/Berlin"`).

Each agent section (`agy`, `claude`, `codex`, `opencode`) supports `enabled`,
`show_deadline`, `show_read_tokens`, `show_write_tokens`, `show_percentage`,
and `show_model`. Invalid or missing settings use the defaults in the example.
Set `enabled` to `false` to clear that agent's cache token without disabling the
other agents. Changes apply on the next Herdr scan; reinstallation is not required.

By default all agents use the same compact display: estimated expiry, cache
percentage, and cached/read tokens. Cache-written tokens are hidden by default
because they are less useful for judging reuse, but can be enabled with
`show_write_tokens: true`.

The plugin reports both the unified token (`$cache`) and granular tokens:
- `$cache`: unified string without middle-dot separators (e.g. `~11:41 99% ⇣95.4k` when hot >5m, `⏰~𝟭𝟭:𝟰𝟭 99% ⇣95.4k` when expiring ≤5m, or `99% ⇣95.4k` when cold)
- `$cache_status`: status symbol + expiry clock (e.g. `~11:41`, `⏰~𝟭𝟭:𝟰𝟭`, or empty when cold)
- `$cache_pct`: cache hit percentage (e.g. `99%`)
- `$cache_tokens`: read (and optional write) token counters (e.g. `⇣95.4k`)
- `$cache_state`: lifecycle state string (`hot`, `expiring`, or `cold`)

Herdr's sidebar configuration (`[ui.sidebar.agents]` in `config.toml`) controls
styling. Using a single `$cache` token avoids Herdr's default multi-token separator (` · `),
and conditional rules dynamically highlight the expiring state:
```toml
[ui.sidebar.agents]
rows = [
  [{ token = "state_icon", bold = true, dim = false }, { token = "agent", fg = "#241835", bold = true, dim = false }],
  [
    { token = "$cache", fg = "#64748b", bold = false, dim = true, rules = [
      { starts_with = "⚠️", bold = true, dim = false, fg = "#7f1d1d" },
      { starts_with = "~", bold = false, dim = false, fg = "#713f78" },
      { starts_with = "♨️", bold = false, dim = false, fg = "#713f78" }
    ] }
  ],
  [{ token = "workspace", fg = "#4c4669", bold = false, dim = false }, { token = "tab", fg = "#4c4669", bold = false, dim = false }]
]
```

## Data and compatibility

The watcher reads only pane identity, native session identity, cwd (for Claude's
fallback path), and an optional native transcript path from `herdr pane list`.
It accepts only `codex`, `agy`, and `claude` panes with a non-empty native ID.
Malformed or incomplete JSONL is ignored, and embedded session IDs are checked
when present. Prompt contents are never transmitted.

`CODEX_SESSIONS_DIR` overrides the Codex session directory. `HODEX_SESSIONS_DIR`
is retained as a compatibility fallback, followed by `~/.codex/sessions`.
AGY checks both `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`
and the native CLI path `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`;
Claude defaults to `$CLAUDE_CONFIG_DIR/projects/<cwd-encoded>/<id>.jsonl`, or
`~/.claude/projects/...`.
OpenCode reads the completed message token ledger and cache counters from
`$OPENCODE_DB_PATH` or `~/.local/share/opencode/opencode.db`.
The AGY statusline writes validated live snapshots to
`~/.cache/herdr-codex-cache/agy-statusline/<conversation-id>.json`; a hot
snapshot remains trusted until the deadline reported by AGY, while cold or
expired snapshots older than two minutes are ignored. Its source is maintained
in chezmoi at `dot_gemini/antigravity-cli/executable_statusline.sh`.
`HERDR_PLUGIN_STATE_DIR` overrides state, lock, and temporary-file storage.
`jq` is required at runtime. The cache deadline is an adaptive estimate with a
30-minute floor and 1-hour ceiling (configurable per agent via `ttl_ceiling`),
not an eviction guarantee; observations are isolated by agent, session, model,
and provider and survive Herdr restarts. Timezone display can be configured via
`"timezone"` in `config.json` (e.g. `"Europe/Berlin"`) or `HERDR_PLUGIN_TIMEZONE`.

Current identity: `cache-hit`, name `Cache Hit`, version `0.1.0`,
macOS and Linux, minimum Herdr `0.7.0`.

## Verification

```bash
cd herdr-cache-plugin
bash -n watch.sh
shellcheck watch.sh lib/*.sh
bash tests/test_watch.sh
bash tests/benchmark.sh
```

The AGY helper is built for macOS arm64 and Linux amd64 with
`scripts/build-agy-usage.sh`; Go and CGO are build-time only and are not
required at runtime.
