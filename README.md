# Herdr Agent Cache HUD

`codex-cache` is a macOS Herdr plugin that reports per-conversation cache usage
for Codex, AGY (`agy`/Antigravity CLI), and Claude as the `cache` pane token.
It reads local rollout/transcript metadata; prompt contents are never
transmitted. AGY prefers the live statusline sidecar written by the
chezmoi-managed `~/.gemini/antigravity-cli/statusline.sh`, then the packaged
native Go decoder for its read-only SQLite conversation database, and finally
transcript parsing. The sidecar is keyed by AGY conversation ID, so multiple
AGY panes can run in parallel without sharing cache state.

## Install and remove

```bash
cd /Users/ek/home/sync/personal/code_repository/pet_projects/harness-plugins
bash -n herdr-codex-cache/watch.sh
shellcheck herdr-codex-cache/watch.sh herdr-codex-cache/lib/*.sh
herdr plugin unlink codex-cache 2>/dev/null || true
herdr plugin link "$PWD/herdr-codex-cache"
herdr plugin list
```

Remove it with `herdr plugin unlink codex-cache`. Herdr invokes the
lock-protected one-shot scanner on startup, handoff, and supported pane
lifecycle/status events; no background process is left running.

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
The AGY statusline writes validated live snapshots to
`~/.cache/herdr-codex-cache/agy-statusline/<conversation-id>.json`; snapshots
older than two minutes are ignored. Its source is maintained in chezmoi at
`dot_gemini/antigravity-cli/executable_statusline.sh`.
`HERDR_PLUGIN_STATE_DIR` overrides state, lock, and temporary-file storage.
`jq` is required at runtime. The cache deadline is an adaptive estimate with a
30-minute floor, not an eviction guarantee; observations are isolated by
agent, session, model, and provider and survive Herdr restarts.

Current identity: `codex-cache`, name `Codex Cache HUD`, version `0.1.0`,
macOS, minimum Herdr `0.7.0`.

## Verification

```bash
bash -n herdr-codex-cache/watch.sh
shellcheck herdr-codex-cache/watch.sh herdr-codex-cache/lib/*.sh
bash herdr-codex-cache/tests/test_watch.sh
bash herdr-codex-cache/tests/benchmark.sh
```

The AGY helper is built for the current macOS arm64 target with
`scripts/build-agy-usage.sh`; Go and CGO are build-time only and are not
required at runtime.
