#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-cache-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CODEX_SESSIONS_DIR="$TMP/sessions" HERDR_PLUGIN_STATE_DIR="$TMP/state" HODEX_SESSIONS_DIR="$TMP/unused"
export AGY_STATUSLINE_STATE_DIR="$TMP/agy-statusline"
mkdir -p "$CODEX_SESSIONS_DIR/2026/09/06"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/codex.sh"; source "$ROOT/lib/agy.sh"; source "$ROOT/lib/claude.sh"; source "$ROOT/lib/cache.sh"
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
assert_eq "$(latest_usage "$roll" "$sid")" $'2026-09-06T10:00:00Z\t1000\t500\tm1\tp1' 'malformed lines are ignored'
assert_eq "$(fmt_tokens 0)" 0 'zero formatting'; assert_eq "$(fmt_tokens 10000)" 10.0k 'thousands formatting'; assert_eq "$(fmt_tokens 2000000)" 2.0M 'millions formatting'
init_state; report_pane() { :; }; clear_pane() { :; }
update_pane paneA "$sid"; d1=$(jq -r .active.deadline "$(state_path paneA)"); update_pane paneA "$sid"; d2=$(jq -r .active.deadline "$(state_path paneA)")
assert_eq "$d1" "$d2" 'cached records do not extend deadline'
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:01:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":0},"model":"m1","model_provider":"p1"}}' >"$roll"
update_pane paneA "$sid"; assert_cmd "jq -e '.active == null and (.observations | length) == 1' \"$(state_path paneA)\"" 'cold transition records observation'
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:02:00Z","payload":{"usage":{"input_tokens":1,"cached_input_tokens":1},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"; assert_cmd "jq -e '.active.model == \"m2\" and .active.provider == \"p2\"' \"$(state_path paneA)\"" 'model/provider are isolated'
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
update_pane paneAGY agy agy-1 /same; assert_cmd "jq -e '.active.agent == \"agy\" and .active.session_id == \"agy-1\" and .active.deadline == ($now + 300)' \"$(state_path paneAGY)\"" 'AGY state is isolated by agent and native ID and deadline'
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
fake="$TMP/fake-herdr"; reports="$TMP/watcher-reports"; panes="$TMP/panes.json"
printf '%s\n' '#!/usr/bin/env bash' 'if [[ "$1 $2" == "pane list" ]]; then cat "$FAKE_PANES"; else printf "%s\n" "$*" >>"$FAKE_REPORTS"; fi' >"$fake"; chmod +x "$fake"
printf '%s\n' '{"result":{"panes":[{"pane_id":"p1","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"aaa111"}},{"pane_id":"p2","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"bbb222"}}]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'p1.*cache=' \"$reports\"" 'watcher reports native session pane'
assert_cmd "grep -q 'p2.*clear-token cache' \"$reports\"" 'missing rollout clears second pane'
printf '%s\n' '{"result":{"panes":[{"pane_id":"p1","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"aaa111"}}]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'p2.*clear-token cache' \"$reports\"" 'closed pane is cleared'
exit "$fail"
