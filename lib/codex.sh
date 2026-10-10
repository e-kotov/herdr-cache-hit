#!/usr/bin/env bash
codex_session_for_pane() {
  local pane=$1 cwd=$2 panes=$3 process script
  command -v python3 >/dev/null 2>&1 || return 1
  script="${PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/lib/codex_session.py"
  process=$("$HERDR_BIN" pane process-info --pane "$pane" 2>/dev/null) || return 1
  jq -c --argjson panes "$panes" '{process:.result.process_info, panes:$panes}' <<<"$process" |
    python3 "$script" "$SESSIONS_DIR" "$cwd" "$pane" 2>/dev/null
}

rollout_matches_session() {
  head -n 100 "$1" 2>/dev/null | jq -R -s -e --arg id "$2" '
    [splits("\\n") | fromjson? | select(type == "object" and .type == "session_meta" and .payload.id == $id)] | length == 1
  ' >/dev/null 2>&1
}
rollout_for_session() {
  local session_id=$1 path script matches record ts best="" best_ts="" first=""
  [[ -d "$SESSIONS_DIR" && "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  # Revert preserves the thread ID and old files. Codex's SQLite pointer is
  # authoritative, even if a discarded branch has more recent usage.
  script="${PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/lib/codex_rollout.py"
  if command -v python3 >/dev/null 2>&1; then
    path=$(python3 "$script" "$SESSIONS_DIR" "$session_id" 2>/dev/null) || path=""
    if [[ -n "$path" ]] && rollout_matches_session "$path" "$session_id"; then
      printf '%s\n' "$path"
      return 0
    fi
  fi

  # Older installations and Bash/jq-only setups have no database reader. Compare
  # actual usage across all matching files, including continuations on later days;
  # touching or copying an old file must not move the cache clock backwards.
  matches=$(find "$SESSIONS_DIR" -type f -name "*$session_id*.jsonl" -print 2>/dev/null) || matches=""
  while IFS= read -r path; do
    if [[ -z "$path" ]] || ! rollout_matches_session "$path" "$session_id"; then continue; fi
    [[ -n "$first" ]] || first=$path
    record=$(latest_usage "$path" "$session_id") || continue
    [[ -n "$record" ]] || continue
    ts=${record%%$'\t'*}
    if [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then
      best=$path; best_ts=$ts
    fi
  done <<<"$matches"
  path=${best:-$first}
  [[ -n "$path" ]] || return 1
  printf '%s\n' "$path"
}
parse_timestamp() {
  local value=${1%%.*}; value=${value%Z}
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$value" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}
latest_usage() {
  local path=$1 session_id=$2
  # Filter out content before JSON parsing, and keep constant-size state. Unlike
  # an arbitrary recent tail, this also finds usage during long tool-only turns.
  awk '/"type"[[:space:]]*:[[:space:]]*"(session_meta|turn_context|token_usage_record|token_count)"/' "$path" 2>/dev/null | jq -Rrn --arg id "$session_id" '
    def nonempty_string: type == "string" and length > 0;
    def token_count: if type == "number" then . >= 0 and floor == . else false end;
    reduce (inputs | fromjson? | select(type == "object" and (.payload | type) == "object")) as $row
      ({model:"codex", provider:"openai", latest:null};
       if $row.type == "session_meta" and $row.payload.id == $id then
         if ($row.payload.model_provider | nonempty_string) then .provider = $row.payload.model_provider else . end
       elif $row.type == "turn_context" then
         (if ($row.payload.model | nonempty_string) then .model = $row.payload.model else . end) |
         (if ($row.payload.model_provider | nonempty_string) then .provider = $row.payload.model_provider else . end)
       elif $row.type == "token_usage_record" or ($row.type == "event_msg" and $row.payload.type == "token_count") then
         (if $row.type == "token_usage_record" then $row.payload.usage
          elif ($row.payload.info | type) == "object" then $row.payload.info.last_token_usage
          else null end) as $usage |
         if ($usage | type) == "object" and
            ($row.payload.session_id == null or $row.payload.session_id == $id) and
            ($row.timestamp | type) == "string" and
            ($row.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
            ($usage.input_tokens | token_count) and ($usage.cached_input_tokens | token_count) then
           .latest = {ts:$row.timestamp, input:$usage.input_tokens, cached:$usage.cached_input_tokens,
             model:(if ($row.payload.model | nonempty_string) then $row.payload.model else .model end),
             provider:(if ($row.payload.model_provider | nonempty_string) then $row.payload.model_provider else .provider end)}
         else . end
       else . end) |
    .latest // empty | [.ts, .input, .cached, .model, .provider] | @tsv' 2>/dev/null
}
codex_usage() {
  local session_id=$1 path record ts input read model provider
  path=$(rollout_for_session "$session_id") || return 1
  record=$(latest_usage "$path" "$session_id") || return 1
  [[ -n "$record" ]] || return 1
  IFS=$'\t' read -r ts input read model provider <<<"$record"
  [[ -n "$model" ]] || model=codex
  [[ -n "$provider" ]] || provider=openai
  printf 'codex\t%s\t%s\t%s\t%s\t0\t0\t0\t%s\t%s\t%s\n' "$session_id" "$ts" "$input" "$read" "$model" "$provider" "$path"
}
