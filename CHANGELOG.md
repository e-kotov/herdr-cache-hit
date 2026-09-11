# Changelog

## [0.1.4] - 2026-09-11
### Fixed
- **Claude Streaming Parser Optimization**: Replaced `tail -n 500 | jq -R -s` with an $O(1)$ streaming reverse reader (`rev_lines | jq -Rrn 'first(inputs | fromjson? ...)'`) to prevent multi-second parser bottlenecks on large JSONL transcripts and networked filesystems (such as HPC Lustre/VAST).
- **Graceful Partial-Line Handling**: Added newline padding and `fromjson?` protection to safely ignore in-flight, unclosed JSON lines during active Claude Code generation.
- **Lock Contention Elimination**: Prevents long-running `jq` processes from holding the plugin lock and dropping interactive `pane.focused` UI click events.

## [0.1.3] - 2026-09-11
### Fixed
- **Mobile Layout Compatibility**: Injected the formatted cache string into the pane's `--display-agent` metadata to ensure prompt-cache statistics remain visible when Herdr dynamically collapses into its hardcoded mobile layout (e.g., on narrow terminal windows or Termux). Herdr's mobile layout ignores custom `config.toml` rows and custom `agent.view.set` sorting rules, rendering `{pane_title} · {status} · {agent}`. This fix ensures the cache hit data is preserved within the `{agent}` slot.
