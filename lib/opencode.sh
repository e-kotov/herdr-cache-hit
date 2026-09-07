#!/usr/bin/env bash
opencode_usage() {
  local session_id=$1 cwd=${2:-} supplied=${3:-}
  [[ -n "$session_id" || -n "$cwd" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local lib_dir
  lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$lib_dir/opencode.py" "$session_id" "$cwd" "$supplied" 2>/dev/null
}
