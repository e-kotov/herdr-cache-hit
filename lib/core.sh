#!/usr/bin/env bash
# shellcheck disable=SC2034
readonly HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
readonly SESSIONS_DIR="${CODEX_SESSIONS_DIR:-${HODEX_SESSIONS_DIR:-$HOME/.codex/sessions}}"
readonly STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/cache-hit}"
readonly CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/cache-hit}"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly FLOOR_SECONDS=1800
readonly DISPLAY_TTL_MS=86400000
readonly SOURCE="herdr-plugin.cache-hit"
readonly LOCK_DIR="$STATE_DIR/watcher.lock"
readonly SEEN_FILE="$STATE_DIR/seen-panes"
readonly ROLLOUT_INDEX="$STATE_DIR/rollouts.index"
readonly ROLLOUT_INDEX_TTL=15
readonly OBSERVATIONS_FILE="$STATE_DIR/observations.json"
require_runtime() { command -v jq >/dev/null 2>&1 || { echo 'cache-hit: jq is required' >&2; return 1; }; }
config_value() {
  [[ -s "$CONFIG_FILE" ]] || return 1
  jq -r --arg agent "$1" --arg key "$2" '
    if (.[$agent] | type) == "object" and (.[$agent] | has($key)) then .[$agent][$key]
    elif (type == "object" and has($key)) then .[$key]
    else empty end
  ' "$CONFIG_FILE" 2>/dev/null
}
config_bool() {
  local value; value=$(config_value "$1" "$2") || value=""
  case "$value" in true|false) printf '%s\n' "$value" ;; *) printf '%s\n' "$3" ;; esac
}
config_str() {
  local value; value=$(config_value "$1" "$2") || value=""
  if [[ -n "$value" ]]; then printf '%s\n' "$value"; else printf '%s\n' "$3"; fi
}
config_int() {
  local value; value=$(config_value "$1" "$2") || value=""
  if [[ "$value" =~ ^[0-9]+$ ]]; then printf '%s\n' "$value"; else printf '%s\n' "$3"; fi
}
config_agent_enabled() { [[ "$(config_bool "$1" enabled true)" == true ]]; }
init_state() { mkdir -p "$STATE_DIR" 2>/dev/null || return 1; }
atomic_install() { mv -f "$1" "$2"; }
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then :; else
    local owner; owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null && return 1
    rm -rf "$LOCK_DIR" 2>/dev/null || return 1; mkdir "$LOCK_DIR" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" >"$LOCK_DIR/pid"; printf '%s\n' "$$:$(date +%s)" >"$LOCK_DIR/identity"
}
cleanup() {
  local f; for f in "$STATE_DIR"/*.tmp "$STATE_DIR"/seen.*; do [[ -e "$f" ]] && rm -f "$f"; done
  [[ -f "$LOCK_DIR/pid" && "$(cat "$LOCK_DIR/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$LOCK_DIR"
}
fmt_tokens() { awk -v n="${1:-0}" 'BEGIN { if (n >= 1000000) printf "%.1fM", n / 1000000; else if (n >= 1000) printf "%.1fk", n / 1000; else printf "%d", n }'; }
fmt_clock() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null; }
report_pane() { "$HERDR_BIN" pane report-metadata "$1" --source "$SOURCE" --agent "$2" --token "cache=$3" --ttl-ms "${4:-15000}" >/dev/null 2>&1; }
clear_pane() { "$HERDR_BIN" pane report-metadata "$1" --source "$SOURCE" --agent "${2:-codex}" --clear-token cache --ttl-ms 15000 >/dev/null 2>&1 || true; }
