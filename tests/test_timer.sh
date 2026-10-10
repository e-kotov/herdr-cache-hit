#!/usr/bin/env bash
set -eu
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cache-hit-timer-test.XXXXXX")
export HERDR_PLUGIN_STATE_DIR="$TMP/state" HERDR_PLUGIN_CONFIG_DIR="$TMP/config"
export TIMER_TEST_ROOT="$ROOT" TIMER_TEST_DIR="$TMP"
export HERDR_BIN_PATH="$TMP/herdr"
unset HERDR_NO_TIMER
# shellcheck source=lib/core.sh
source "$ROOT/lib/core.sh"
trap 'cancel_timer; rm -rf "$TMP"' EXIT
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
ln -s "$ROOT/lib" "$TMP/lib"
printf '{"bold_time":false}\n' >"$CONFIG_FILE"

# One fixed cache observation expires while no Herdr events occur. Exercise the
# real watcher, rendering and background timer; only the adapter/API are fakes.
export TIMER_TEST_TIMESTAMP
# Git Bash process startup can consume several seconds per scan. Leave enough
# time to observe repeated rearming before expiry on every supported platform.
TIMER_TEST_TIMESTAMP=$(python3 -c 'import datetime,time; print(datetime.datetime.fromtimestamp(time.time()-3580, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
cat >"$TMP/herdr" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == 'api snapshot' ]]; then
  printf '{"result":{"snapshot":{"panes":[{"pane_id":"timer-pane","agent":"claude","agent_session":{"kind":"id","value":"timer-session"}}]}}}\n'
elif [[ "$1 $2" == 'pane report-metadata' ]]; then
  printf '%s\n' "$*" >>"$TIMER_TEST_DIR/reports"
fi
SH
chmod +x "$TMP/herdr"
cat >"$TMP/watch.sh" <<'SH'
#!/usr/bin/env bash
source "$TIMER_TEST_ROOT/watch.sh"
PLUGIN_DIR="$TIMER_TEST_DIR"
claude_usage() {
  printf 'claude\ttimer-session\t%s\t1000\t800\t50\t0\t50\tmodel\tanthropic\t/same\n' "$TIMER_TEST_TIMESTAMP"
}
# Accelerate the normal 15-second scan without replacing the timer functions.
next_wake_delay() { (( $1 > 0 )) && printf '1\n'; }
watch_main
SH
bash "$TMP/watch.sh"

finished=false
for ((attempt=0; attempt<40; attempt++)); do
  if [[ -f "$TMP/reports" ]] && grep -q -- '--token cache_state=cold' "$TMP/reports"; then
    finished=true
    break
  fi
  sleep 1
done
if [[ "$finished" != true ]]; then
  echo 'not ok - background timer reaches cold without pane events'
  exit 1
fi
if ! grep -q -- '--token cache_state=expiring' "$TMP/reports" || (( $(wc -l <"$TMP/reports") < 3 )); then
  echo 'not ok - timer must rearm across multiple scans before expiry'
  exit 1
fi
# Wait for the final scan to retire the timer and release the watcher lock.
for ((attempt=0; attempt<5; attempt++)); do
  [[ -f "$TIMER_PID_FILE" || -d "$LOCK_DIR" ]] || break
  sleep 1
done
if [[ -f "$TIMER_PID_FILE" || -d "$LOCK_DIR" ]]; then
  echo 'not ok - final cold scan retires the timer and watcher lock'
  exit 1
fi
echo 'ok - background timer rearms and reaches cold without pane events'
