#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cache-hit-test.XXXXXX")
trap 'cancel_timer; rm -rf "$TMP"' EXIT
export CODEX_SESSIONS_DIR="$TMP/sessions" HERDR_PLUGIN_STATE_DIR="$TMP/state" HODEX_SESSIONS_DIR="$TMP/unused"
export AGY_STATUSLINE_STATE_DIR="$TMP/agy-statusline"
export HERDR_PLUGIN_CONFIG_DIR="$TMP/config"
export HERDR_NO_TIMER=1
mkdir -p "$CODEX_SESSIONS_DIR/2026/09/06"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/codex.sh"; source "$ROOT/lib/agy.sh"; source "$ROOT/lib/claude.sh"; source "$ROOT/lib/opencode.sh"; source "$ROOT/lib/cache.sh"
fail=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fail=1; }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else printf 'not ok - %s\n' "$3"; fail=1; fi; }
assert_cmd() { if eval "$1" >/dev/null 2>&1; then ok "$2"; else not_ok "$2"; fi; }
sid=aaa111; roll="$CODEX_SESSIONS_DIR/2026/09/06/rollout-$sid.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111","cwd":"/same"}}' 'not json' '{"type":"token_usage_record","timestamp":"2026-09-06T10:00:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":500},"model":"m1","model_provider":"p1"}}' '{"type":"incomplete"}' >"$roll"
printf '%s\n' '{"type":"session_meta","payload":{"id":"wrong"}}' >"$TMP/rollout-bbb222.jsonl"
assert_eq "$(rollout_for_session "$sid")" "$roll" 'native ID selects exact rollout'
assert_eq "$(rollout_for_session bbb222 || true)" '' 'wrong rollout identity is rejected'

# UUIDv7 fast path test: historical session from May 2026 resolved without scanning
uuid7="019e0779-180e-7ec2-9d3c-e18de4536265"
mkdir -p "$CODEX_SESSIONS_DIR/2026/05/08"
roll7="$CODEX_SESSIONS_DIR/2026/05/08/rollout-$uuid7.jsonl"
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$uuid7\"}}" >"$roll7"
assert_eq "$(rollout_for_session "$uuid7")" "$roll7" 'UUIDv7 timestamp selects exact historical rollout'

assert_eq "$(latest_usage "$roll" "$sid")" $'2026-09-06T10:00:00Z\t1000\t500\tm1\tp1' 'malformed lines are ignored'
assert_eq "$(fmt_tokens 0)" 0 'zero formatting'; assert_eq "$(fmt_tokens 10000)" 10.0k 'thousands formatting'; assert_eq "$(fmt_tokens 2000000)" 2.0M 'millions formatting'
init_state; report_pane() { :; }; clear_pane() { :; }
update_pane paneA "$sid"; d1=$(jq -r .active.deadline "$(state_path paneA)"); update_pane paneA "$sid"; d2=$(jq -r .active.deadline "$(state_path paneA)")
assert_eq "$d1" "$d2" 'cached records do not extend deadline'
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
printf '%s\n' '{"codex":{"enabled":false}}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
assert_eq "$(config_bool codex enabled true)" false 'per-agent enabled setting is read'
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.json"
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:01:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":0},"model":"m1","model_provider":"p1"}}' >"$roll"
update_pane paneA "$sid"; assert_cmd "jq -e '.active == null' \"$(state_path paneA)\"" 'cold transition sets active null'
assert_cmd "jq -e '.\"p1:m1\" | length == 1' \"$OBSERVATIONS_FILE\"" 'cold transition records observation in shared observations.json'

# Switch to m2/p2 at 10:02:00Z (hit_at = 10:02:00Z, deadline = 10:32:00Z, ttl = 1800)
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:02:00Z","payload":{"usage":{"input_tokens":1,"cached_input_tokens":1},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"; assert_cmd "jq -e '.active.model == \"m2\" and .active.provider == \"p2\"' \"$(state_path paneA)\"" 'model/provider are isolated'

# Surprise hit past deadline: prompt at 10:47:00Z (45 min = 2700s > 1800s deadline) with cache read hits
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:47:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":800},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"
assert_cmd "jq -e '.\"p2:m2\" | (length == 1 and .[0] == 2700)' \"$OBSERVATIONS_FILE\"" 'surprise hit past deadline records survival observation'

# Cross-pane sharing: paneB with same model/provider reads from shared observations
record_observation p2 m2 3300
learned=$(get_learned_ttl p2 m2 1800)
assert_eq "$learned" 3000 'shared observations compute learned TTL across panes'

# Prefix shift guardrail: cold drop within 20s does not add to observations
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:47:20Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":0},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"
assert_cmd "jq -e '.\"p2:m2\" | length == 2' \"$OBSERVATIONS_FILE\"" 'prefix shift under 60s is ignored by observation guardrail'

printf '%s\n' corrupt >"$(state_path paneB)"; update_pane paneB "$sid"; assert_cmd "jq -e . \"$(state_path paneB)\"" 'corrupt state is rebuilt'

# AGY and Claude adapter fixtures exercise native IDs, recent-tail parsing, and
# independent read/write counters without involving either CLI's status command.
agy_root="$TMP/agy"; claude_root="$TMP/claude"; export AGY_HOME="$agy_root" CLAUDE_CONFIG_DIR="$claude_root"
mkdir -p "$agy_root/antigravity/brain/agy-1/.system_generated/logs" "$claude_root/projects/-same"
agy_file="$agy_root/antigravity/brain/agy-1/.system_generated/logs/transcript.jsonl"
printf '%s\n' '{"conversation_id":"wrong","created_at":"2026-09-06T10:00:00Z","context_window":{"current_usage":{"input_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}},"model":"bad"}' 'partial' '{"conversationId":"agy-1","created_at":"2026-09-06T10:01:00Z","context_window":{"current_usage":{"input_tokens":12000,"cache_read_input_tokens":48900,"cache_creation_input_tokens":3000}},"model":"Gemini 3.8 Flash"}' >"$agy_file"
assert_eq "$(agy_usage agy-1 | cut -f1-10)" $'agy\tagy-1\t2026-09-06T10:01:00Z\t12000\t48900\t3000\t0\t0\tGemini 3.8 Flash\tantigravity' 'AGY transcript maps read/write fields and rejects mismatched IDs'
assert_eq "$(agy_usage missing || true)" '' 'missing AGY transcript is unavailable'
agy_cli_root="$TMP/agy-cli"; mkdir -p "$agy_cli_root/brain/agy-cli-1/.system_generated/logs"; export AGY_CLI_HOME="$agy_cli_root"
printf '%s\n' '{"conversation_id":"agy-cli-1","created_at":"2026-09-06T10:03:00Z","context_window":{"current_usage":{"input_tokens":10,"cache_read_input_tokens":4,"cache_creation_input_tokens":2}},"model":"Gemini CLI"}' >"$agy_cli_root/brain/agy-cli-1/.system_generated/logs/transcript.jsonl"
assert_eq "$(agy_transcript_path agy-cli-1)" "$agy_cli_root/brain/agy-cli-1/.system_generated/logs/transcript.jsonl" 'AGY native CLI transcript path is discovered'
claude_file="$claude_root/projects/-same/claude-1.jsonl"
printf '%s\n' '{"sessionId":"claude-1","timestamp":"2026-09-06T10:02:00Z","message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":400,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":25}},"model":"claude-sonnet"}}' >"$claude_file"
assert_eq "$(claude_usage claude-1 /same | cut -f1-10)" $'claude\tclaude-1\t2026-09-06T10:02:00Z\t1000\t400\t75\t50\t25\tclaude-sonnet\tanthropic' 'Claude transcript maps cache lifetime creation counters'
now=$(date +%s)
mkdir -p "$AGY_STATUSLINE_STATE_DIR"
jq -n --argjson now "$now" '{session_id:"agy-1",observed_at:$now,input_tokens:900,cache_read_tokens:800,cache_creation_tokens:100,model:"Gemini live",provider:"antigravity",deadline:($now+300)}' >"$AGY_STATUSLINE_STATE_DIR/agy-1.json"
jq -n --argjson now "$now" '{session_id:"agy-2",observed_at:$now,input_tokens:700,cache_read_tokens:0,cache_creation_tokens:600,model:"Gemini second",provider:"antigravity",deadline:($now+300)}' >"$AGY_STATUSLINE_STATE_DIR/agy-2.json"
assert_eq "$(agy_usage agy-1 | cut -f1,2,4-10)" $'agy\tagy-1\t900\t800\t100\t0\t0\tGemini live\tantigravity' 'AGY live statusline sidecar takes precedence'
assert_eq "$(agy_usage agy-2 | cut -f1,2,4-10)" $'agy\tagy-2\t700\t0\t600\t0\t0\tGemini second\tantigravity' 'parallel AGY sidecars remain session-isolated'
jq --argjson now "$now" '.observed_at = ($now - 180)' "$AGY_STATUSLINE_STATE_DIR/agy-1.json" >"$AGY_STATUSLINE_STATE_DIR/agy-1.tmp" && mv "$AGY_STATUSLINE_STATE_DIR/agy-1.tmp" "$AGY_STATUSLINE_STATE_DIR/agy-1.json"
assert_eq "$(agy_usage agy-1 | cut -f1,2,4-10)" $'agy\tagy-1\t900\t800\t100\t0\t0\tGemini live\tantigravity' 'AGY hot sidecar survives statusline silence until deadline'
jq -n --argjson now "$now" '{session_id:"agy-1",observed_at:($now-180),input_tokens:900,cache_read_tokens:800,cache_creation_tokens:100,model:"Gemini live",provider:"antigravity",deadline:($now+300)}' >"$AGY_STATUSLINE_STATE_DIR/agy-1.json"
update_pane paneAGY agy agy-1 /same; assert_cmd "jq -e '.active.agent == \"agy\" and .active.session_id == \"agy-1\" and .active.deadline == ($now + 300)' \"$(state_path paneAGY)\"" 'AGY state is isolated by agent and native ID and deadline'
jq --argjson now "$now" '.deadline = ($now - 1)' "$AGY_STATUSLINE_STATE_DIR/agy-1.json" >"$AGY_STATUSLINE_STATE_DIR/agy-1.tmp" && mv "$AGY_STATUSLINE_STATE_DIR/agy-1.tmp" "$AGY_STATUSLINE_STATE_DIR/agy-1.json"
assert_eq "$(agy_usage agy-1 | cut -f1,2,4-10)" $'agy\tagy-1\t12000\t48900\t3000\t0\t0\tGemini 3.8 Flash\tantigravity' 'expired AGY sidecar falls back to transcript data'
update_pane paneClaude claude claude-1 /same; assert_cmd "jq -e '.active.agent == \"claude\" and .active.provider == \"anthropic\"' \"$(state_path paneClaude)\"" 'Claude state is isolated by agent and provider'
mkdir "$STATE_DIR/watcher.lock"; printf '%s\n' 999999 >"$STATE_DIR/watcher.lock/pid"; assert_cmd 'acquire_lock' 'stale lock is recoverable'; cleanup
if command -v python3 >/dev/null 2>&1; then
  py=$(python3 - "$roll" <<'PY'
import json,sys
last=''
for line in open(sys.argv[1]):
 try: o=json.loads(line)
 except json.JSONDecodeError: continue
 if o.get('type')=='token_usage_record':
  u=o.get('payload',{}).get('usage',{})
  if isinstance(u.get('input_tokens'),int) and isinstance(u.get('cached_input_tokens'),int): last='\t'.join([o.get('timestamp',''),str(u['input_tokens']),str(u['cached_input_tokens']),o.get('payload',{}).get('model',''),o.get('payload',{}).get('model_provider','')])
print(last)
PY
); assert_eq "$py" "$(latest_usage "$roll" "$sid")" 'Bash and Python fixture outputs agree'; fi

if command -v python3 >/dev/null 2>&1; then
  opencode_db="$TMP/opencode.db"
  export OPENCODE_DB_PATH="$opencode_db"
  python3 -c "
import sqlite3
con = sqlite3.connect('$opencode_db')
cur = con.cursor()
cur.execute('CREATE TABLE session (id text PRIMARY KEY, directory text, time_created integer, time_updated integer, model text, tokens_input integer, tokens_cache_read integer, tokens_cache_write integer)')
cur.execute('CREATE TABLE message (id text PRIMARY KEY, session_id text, time_created integer, time_updated integer, data text)')
cur.execute('INSERT INTO session VALUES (?, ?, ?, ?, ?, ?, ?, ?)', ('oc-1', '/same', 1000, 2000, '{\"id\":\"m1\",\"providerID\":\"p1\"}', 10, 20, 5))
cur.execute('INSERT INTO message VALUES (?, ?, ?, ?, ?)', ('m1', 'oc-1', 1000, 2000, '{\"role\":\"assistant\",\"tokens\":{\"input\":15,\"cache\":{\"read\":45,\"write\":10}},\"modelID\":\"gpt-5\",\"providerID\":\"kiconnect\",\"time\":{\"completed\":1788784328200}}'))
con.commit()
con.close()
"
  assert_eq "$(opencode_usage oc-1 | cut -f1,2,4-10)" $'opencode\toc-1\t15\t45\t10\t0\t0\tgpt-5\tkiconnect' 'OpenCode message maps tokens, model, and provider'
  update_pane paneOC opencode oc-1 /same
  assert_cmd "jq -e '.active.agent == \"opencode\" and .active.session_id == \"oc-1\" and .active.model == \"gpt-5\"' \"$(state_path paneOC)\"" 'OpenCode pane state is recorded'
fi

fake="$TMP/fake-herdr"; reports="$TMP/watcher-reports"; panes="$TMP/panes.json"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'if [[ "$1 $2" == "pane list" ]]; then cat "$FAKE_PANES"; else printf "%s\n" "$*" >>"$FAKE_REPORTS"; fi' >"$fake"; chmod +x "$fake"
printf '%s\n' '{"result":{"panes":[{"pane_id":"p1","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"aaa111"}},{"pane_id":"p2","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"bbb222"}},{"pane_id":"p3","agent":"agy","cwd":"/same","agent_session":{"kind":"id","value":"agy-missing"}},{"pane_id":"p4","agent":"opencode","cwd":"/same","agent_session":{"kind":"id","value":"oc-1"}}]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'p1.*cache=' \"$reports\"" 'watcher reports native session pane'
assert_cmd "grep -q 'p1.*cache_status=' \"$reports\"" 'watcher reports granular cache_status'
assert_cmd "grep -q 'p1.*cache_pct=' \"$reports\"" 'watcher reports granular cache_pct'
assert_cmd "grep -q 'p1.*cache_tokens=' \"$reports\"" 'watcher reports granular cache_tokens'
assert_cmd "grep -q 'p1.*cache_state=' \"$reports\"" 'watcher reports granular cache_state'
assert_cmd "grep -q 'p2.*clear-token cache' \"$reports\"" 'missing rollout clears second pane'
assert_cmd "grep -q 'p3.*cache=.*❄' \"$reports\"" 'missing AGY usage reports cold'
assert_cmd "grep -q 'p4.*agent opencode.*cache=' \"$reports\"" 'watcher reports OpenCode session pane'
printf '%s\n' '{"result":{"panes":[{"pane_id":"p1","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"aaa111"}}]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'p2.*clear-token cache' \"$reports\"" 'closed pane is cleared'

# Configurable symbols and expiring threshold tests
now=$(date +%s)
last_reported=""
report_pane() { last_reported="$3"; }
sig="codex|s1|m|p|1000|800|0|0|0"
codex_usage() { printf 'codex\ts1\t%s\t1000\t800\t0\t0\t0\tm\tp\t/same\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

# 1. Hot state: deadline 10 minutes ahead (> 300s)
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:$now,deadline:($now+600)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == '~'* && \"$last_reported\" != *'♨️'* ]]" 'hot cache displays clean clock without emoji by default'
assert_cmd "[[ \"$last_reported\" =~ ~[0-9]{2}:[0-9]{2} ]]" 'hot cache clock remains non-bold before threshold (>5m)'

# 2. Expiring state: deadline 4 minutes ahead (<= 300s)
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:($now-1560),deadline:($now+240)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'⏰'* ]]" 'expiring cache under 5m displays ⏰ by default'
assert_cmd "[[ \"$last_reported\" =~ [𝟬-𝟵] ]]" 'expiring cache clock converts to bold digits under threshold (<=5m)'

# 3. Custom config override: custom hot, expiring symbols, and custom bold threshold
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
printf '%s\n' '{"hot_symbol":"🔥","expiring_symbol":"⚡","expiring_threshold_seconds":60,"bold_threshold_seconds":60}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'🔥'* ]]" 'custom hot symbol and threshold are respected'
assert_cmd "[[ \"$last_reported\" =~ [0-9]{2}:[0-9]{2} ]]" 'clock stays non-bold when above custom bold threshold'
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:($now-1770),deadline:($now+30)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'⚡'* ]]" 'custom expiring symbol is respected'
assert_cmd "[[ \"$last_reported\" =~ [𝟬-𝟵] ]]" 'clock becomes bold when under custom bold threshold'

# 4. Arbitrary user text/emoji/empty symbols
printf '%s\n' '{"hot_symbol":"[HOT]","expiring_symbol":"","cold_symbol":"🧊"}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:$now,deadline:($now+600)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'[HOT]'* ]]" 'arbitrary text or emoji symbols are allowed'
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.json"

# TTL ceiling guardrail tests
# 1. Observations exceeding ceiling (e.g. 44005s from multi-hour idle) are rejected
record_observation pCeil mCeil 44005 3600
assert_cmd "! jq -e 'has(\"pCeil:mCeil\")' \"$OBSERVATIONS_FILE\"" 'observations exceeding ceiling are rejected by record_observation'

# 2. Corrupted or legacy observations exceeding ceiling in observations.json are filtered by get_learned_ttl
jq '.["pCeil:mCeil"] = [44005, 3000, 3200]' "$OBSERVATIONS_FILE" >"$OBSERVATIONS_FILE.tmp" && mv "$OBSERVATIONS_FILE.tmp" "$OBSERVATIONS_FILE"
learned_clamped=$(get_learned_ttl pCeil mCeil 1800 3600)
assert_eq "$learned_clamped" 3100 'get_learned_ttl filters out legacy observations exceeding ceiling'

# 3. Session isolation: surprise hit does NOT record across different session IDs in the same pane
roll_s2="$CODEX_SESSIONS_DIR/2026/09/06/rollout-s2.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"id":"s2"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T15:00:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":800},"model":"mIso","model_provider":"pIso"}}' >"$roll_s2"
jq -n --arg sig "codex|s1|mIso|pIso|1000|800|0|0|0" '{active:{agent:"codex",session_id:"s1",model:"mIso",provider:"pIso",signature:$sig,hit_at:1788690000,deadline:1788691800},observations:[]}' >"$(state_path paneIso)"
update_pane paneIso codex s2
assert_cmd "! jq -e 'has(\"pIso:mIso\")' \"$OBSERVATIONS_FILE\"" 'different session ID does not record surprise hit across sessions'

# 4. Timezone override in fmt_clock
clock_epoch=1788858000 # 2026-09-08 09:00:00 UTC
HERDR_PLUGIN_TIMEZONE="UTC" assert_eq "$(HERDR_PLUGIN_TIMEZONE="UTC" fmt_clock "$clock_epoch")" "09:00" 'fmt_clock formats in UTC with HERDR_PLUGIN_TIMEZONE'
HERDR_PLUGIN_TIMEZONE="Europe/Berlin" assert_eq "$(HERDR_PLUGIN_TIMEZONE="Europe/Berlin" fmt_clock "$clock_epoch")" "11:00" 'fmt_clock formats in CEST (+2) with HERDR_PLUGIN_TIMEZONE'
printf '%s\n' '{"timezone":"UTC"}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
assert_eq "$(fmt_clock "$clock_epoch")" "09:00" 'fmt_clock respects timezone from config.json'
assert_eq "$(to_bold_digits "09:00")" "𝟬𝟵:𝟬𝟬" 'to_bold_digits converts ascii numbers to mathematical sans-serif bold glyphs'
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.json"
# 5. Timer scheduling and cancellation
schedule_wake 100
assert_cmd "[[ -s \"$TIMER_PID_FILE\" ]]" 'schedule_wake records timer PID'
tpid=$(cat "$TIMER_PID_FILE")
assert_cmd "kill -0 \"$tpid\" 2>/dev/null" 'scheduled timer process is running'
cancel_timer
assert_cmd "[[ ! -f \"$TIMER_PID_FILE\" ]]" 'cancel_timer removes PID file'
assert_cmd "! kill -0 \"$tpid\" 2>/dev/null" 'cancel_timer terminates timer process'

exit "$fail"
