#!/usr/bin/env bash
rollout_for_session() {
  local session_id=$1 path meta index_age now candidate
  [[ -d "$SESSIONS_DIR" && "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  # UUIDv7 fast path: Codex session IDs are UUIDv7, whose first 48 bits encode the
  # millisecond creation timestamp. Compute the exact YYYY/MM/DD directory directly
  # without scanning the directory tree or building indices.
  if [[ "${session_id:14:1}" == "7" && "${#session_id}" -eq 36 ]]; then
    local hex="${session_id:0:8}${session_id:9:4}"
    local sec=$(( 16#$hex / 1000 ))
    local d_utc d_loc
    d_utc=$(date -u -r "$sec" +%Y/%m/%d 2>/dev/null || date -u -d "@$sec" +%Y/%m/%d 2>/dev/null)
    d_loc=$(date -r "$sec" +%Y/%m/%d 2>/dev/null || date -d "@$sec" +%Y/%m/%d 2>/dev/null)
    for candidate in "$SESSIONS_DIR/$d_utc"/*"$session_id"*.jsonl "$SESSIONS_DIR/$d_loc"/*"$session_id"*.jsonl; do
      if [[ -f "$candidate" ]]; then
        meta=$(head -n 100 "$candidate" 2>/dev/null | jq -R -s --arg id "$session_id" '[splits("\n") | fromjson? | select(type == "object" and .type == "session_meta" and .payload.id == $id)] | length' 2>/dev/null) || continue
        if [[ "$meta" == 1 ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      fi
    done
  fi

  # Fast path: check flat and recent date-partitioned paths first (avoids full tree scans on network filesystems)
  for candidate in \
    "$SESSIONS_DIR"/*"$session_id"*.jsonl \
    "$SESSIONS_DIR"/$(date +%Y/%m/%d)/*"$session_id"*.jsonl \
    "$SESSIONS_DIR"/$(date -u +%Y/%m/%d)/*"$session_id"*.jsonl \
    "$SESSIONS_DIR"/$(date +%Y/%m)/*/*"$session_id"*.jsonl; do
    if [[ -f "$candidate" ]]; then
      meta=$(head -n 100 "$candidate" 2>/dev/null | jq -R -s --arg id "$session_id" '[splits("\n") | fromjson? | select(type == "object" and .type == "session_meta" and .payload.id == $id)] | length' 2>/dev/null) || continue
      if [[ "$meta" == 1 ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done

  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  now=$(date +%s)
  index_age=999999
  if [[ -f "$ROLLOUT_INDEX" ]]; then
    local mtime
    mtime=$(stat -c %Y "$ROLLOUT_INDEX" 2>/dev/null || stat -f %m "$ROLLOUT_INDEX" 2>/dev/null || printf 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    index_age=$((now - mtime))
  fi
  if (( index_age >= ROLLOUT_INDEX_TTL )); then
    local tmp; tmp=$(mktemp "${ROLLOUT_INDEX}.XXXXXX") || return 1
    find "$SESSIONS_DIR" -type f -name '*.jsonl' -print0 2>/dev/null | while IFS= read -r -d '' path; do
      printf '%s\t%s\n' "$(basename "$path")" "$path"
    done >"$tmp"
    mv -f "$tmp" "$ROLLOUT_INDEX"
  fi
  while IFS=$'\t' read -r name path; do
    [[ "$name" == *"$session_id"* ]] || continue
    meta=$(head -n 100 "$path" 2>/dev/null | jq -R -s --arg id "$session_id" '[splits("\n") | fromjson? | select(type == "object" and .type == "session_meta" and .payload.id == $id)] | length' 2>/dev/null) || continue
    [[ "$meta" == 1 ]] && { printf '%s\n' "$path"; return 0; }
  done <"$ROLLOUT_INDEX"
  # The index is only an optimization. During an active session, a refresh can
  # race rollout creation; validate matching filenames directly before
  # declaring the native session unavailable.
  local matches
  matches=$(find "$SESSIONS_DIR" -type f -name "*$session_id*.jsonl" -print 2>/dev/null) || matches=""
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    meta=$(head -n 100 "$path" 2>/dev/null | jq -R -s --arg id "$session_id" '[splits("\n") | fromjson? | select(type == "object" and .type == "session_meta" and .payload.id == $id)] | length' 2>/dev/null) || continue
    [[ "$meta" == 1 ]] && { printf '%s\n' "$path"; return 0; }
  done <<<"$matches"
  return 1
}
parse_timestamp() {
  local value=${1%%.*}; value=${value%Z}
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$value" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}
latest_usage() {
  local path=$1 session_id=$2
  awk '/"type"[[:space:]]*:[[:space:]]*"token_usage_record"/' "$path" 2>/dev/null | tail -n 500 | jq -R -s -r --arg id "$session_id" '
    [splits("\n") | fromjson? | select(type == "object" and .type == "token_usage_record") |
      {ts: .timestamp, input: .payload.usage.input_tokens, cached: .payload.usage.cached_input_tokens,
       model: (.payload.model // ""), provider: (.payload.model_provider // "")} |
      select((.ts | type) == "string" and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))) |
      select((.input | type) == "number" and .input >= 0 and (.input | floor) == .input) |
      select((.cached | type) == "number" and .cached >= 0 and (.cached | floor) == .cached) |
      select((.model | type) == "string" and (.provider | type) == "string") ] |
      last // empty | [.ts, .input, .cached, .model, .provider] | @tsv' 2>/dev/null
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
