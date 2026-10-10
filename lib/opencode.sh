#!/usr/bin/env bash
opencode_session_for_pane() {
  local pane=$1 cwd=$2 panes=$3 title=${4:-} process script
  command -v python3 >/dev/null 2>&1 || return 1
  script="${PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/lib/opencode_session.py"
  process=$("$HERDR_BIN" pane process-info --pane "$pane" 2>/dev/null) || return 1
  jq -c --argjson panes "$panes" '{process:.result.process_info, panes:$panes}' <<<"$process" |
    python3 "$script" "$cwd" "$pane" "$title" 2>/dev/null
}

opencode_usage() {
  local session_id=$1 cwd=${2:-} supplied=${3:-}
  [[ -n "$session_id" || -n "$cwd" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local lib_dir
  lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$lib_dir/opencode.py" "$session_id" "$cwd" "$supplied" 2>/dev/null
}
