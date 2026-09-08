#!/usr/bin/env bash
# shellcheck disable=SC2034
VIEW_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/core.sh
. "$VIEW_LIB_DIR/core.sh"

readonly SORT_STATE_FILE="$STATE_DIR/sort_mode.json"

herdr_view_rpc() {
  local method=$1 params_json=$2
  python3 -c '
import socket, json, sys, os

sock = os.environ.get("HERDR_SOCKET_PATH") or os.path.expanduser("~/.config/herdr/herdr.sock")
if not os.path.exists(sock):
    sys.exit(0)

method = sys.argv[1]
params = json.loads(sys.argv[2])
req = {"jsonrpc": "2.0", "id": "1", "method": method, "params": params}

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2.0)
    s.connect(sock)
    s.sendall(json.dumps(req).encode("utf-8") + b"\n")
    line = s.makefile("r").readline()
    s.close()
    if not line:
        sys.exit(0)
    res = json.loads(line)
    if "error" in res:
        sys.stderr.write(str(res["error"]) + "\n")
        sys.exit(1)
except Exception as e:
    sys.stderr.write(str(e) + "\n")
    sys.exit(1)
' "$method" "$params_json"
}

get_sort_mode() {
  if [[ -s "$SORT_STATE_FILE" ]]; then
    local mode
    mode=$(jq -r '.mode // "grouped"' "$SORT_STATE_FILE" 2>/dev/null) || mode="grouped"
    case "$mode" in
      expiry|priority|grouped) printf '%s\n' "$mode"; return 0 ;;
    esac
  fi
  printf 'grouped\n'
}

save_sort_mode() {
  local mode=$1
  init_state || return 0
  printf '{"mode":"%s"}\n' "$mode" >"$SORT_STATE_FILE.tmp" 2>/dev/null && \
    atomic_install "$SORT_STATE_FILE.tmp" "$SORT_STATE_FILE"
}

apply_sort_mode() {
  local mode=$1
  case "$mode" in
    expiry)
      herdr_view_rpc "agent.view.set" '{
        "source": "plugin:cache-hit",
        "label": "expiry",
        "sort": [
          {"field": {"token": "cache_deadline"}, "order": "asc"},
          {"field": "attention", "order": "desc"},
          {"field": "state_change_seq", "order": "desc"}
        ]
      }'
      ;;
    priority)
      herdr_view_rpc "agent.view.set" '{
        "source": "plugin:cache-hit",
        "label": "priority",
        "sort": [
          {"field": "attention", "order": "desc"},
          {"field": "state_change_seq", "order": "desc"}
        ]
      }'
      ;;
    grouped|*)
      herdr_view_rpc "agent.view.clear" '{
        "source": "plugin:cache-hit"
      }'
      ;;
  esac
}

set_sort_mode() {
  local mode=$1
  case "$mode" in
    expiry|priority|grouped) ;;
    *) echo "Invalid sort mode: $mode (must be expiry, priority, or grouped)" >&2; return 1 ;;
  esac
  apply_sort_mode "$mode"
  save_sort_mode "$mode"
}

cycle_sort_mode() {
  local current next
  current=$(get_sort_mode)
  case "$current" in
    grouped)  next="priority" ;;
    priority) next="expiry" ;;
    expiry|*) next="grouped" ;;
  esac
  set_sort_mode "$next"
  printf '%s\n' "$next"
}

restore_sort_mode() {
  local current
  current=$(get_sort_mode)
  apply_sort_mode "$current"
}
