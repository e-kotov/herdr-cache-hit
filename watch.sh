#!/usr/bin/env bash
# Herdr plugin prototype: discover native Codex panes and publish cache HUD data.
set -u

readonly HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
readonly SESSIONS_DIR="${HODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
readonly STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$HOME/.cache/hodex-plugin}"
readonly FLOOR_SECONDS=1800
readonly POLL_SECONDS=2

mkdir -p "$STATE_DIR" 2>/dev/null || exit 1

fmt_tokens() {
  awk -v n="${1:-0}" 'BEGIN { if (n >= 1000000) printf "%.1fM", n / 1000000; else if (n >= 1000) printf "%.1fk", n / 1000; else printf "%d", n }'
}

fmt_clock() {
  date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null
}

find_session() {
  local cwd=$1 path meta mtime best_path= best_mtime=0
  [[ -d "$SESSIONS_DIR" ]] || return
  while IFS= read -r -d '' path; do
    meta=$(jq -r -s 'map(select(.type == "session_meta"))[0].payload.cwd // empty' "$path" 2>/dev/null) || continue
    [[ "$meta" == "$cwd" ]] || continue
    mtime=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || printf 0)
    [[ "$mtime" -ge "$best_mtime" ]] || continue
    best_path=$path
    best_mtime=$mtime
  done < <(find "$SESSIONS_DIR" -type f -name '*.jsonl' -print0 2>/dev/null)
  [[ -n "$best_path" ]] && printf '%s\n' "$best_path"
}

report() {
  local pane=$1 value=$2 source="herdr-plugin.codex-cache:${pane//:/_}"
  "$HERDR_BIN" pane report-metadata "$pane" --source "$source" \
    --token "cache=$value" --ttl-ms 15000 >/dev/null 2>&1 || true
}

update_pane() {
  local pane=$1 cwd=$2 session record ts input cached model provider key now ttl pct state
  session=$(find_session "$cwd")
  [[ -n "$session" ]] || return
  record=$(tail -n 500 "$session" 2>/dev/null | jq -r -s '[.[] | select(.type == "token_usage_record") | {ts:(.timestamp // ""), usage:(.payload.usage // {}), model:(.payload.model // ""), provider:(.payload.model_provider // "")}] | last // empty | [.ts, (.usage.input_tokens // 0), (.usage.cached_input_tokens // 0), .model, .provider] | @tsv' 2>/dev/null) || return
  [[ -n "$record" ]] || return
  IFS=$'\t' read -r ts input cached model provider <<< "$record"
  input=${input:-0}; cached=${cached:-0}
  [[ "$input" =~ ^[0-9]+$ && "$cached" =~ ^[0-9]+$ ]] || return
  key="$session|$ts|$input|$cached"
  state="$STATE_DIR/state-${pane//:/_}.json"
  [[ -s "$state" ]] || printf '%s\n' '{"last_key":"","hit_at":0,"deadline":0,"observations":[]}' >"$state"

  if [[ "$key" != "$(jq -r '.last_key // ""' "$state" 2>/dev/null)" ]]; then
    if [[ "$cached" -eq 0 ]]; then
      jq --arg key "$key" --argjson now "$(date +%s)" 'if (.hit_at // 0) > 0 then .observations=((.observations // []) + [{seconds:($now-.hit_at)}] | .[-20:]) else . end | .last_key=$key | .hit_at=0 | .deadline=0' "$state" >"$state.tmp" 2>/dev/null && mv -f "$state.tmp" "$state"
    else
      now=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${ts%%.*}" +%s 2>/dev/null || date -u -d "${ts%%.*}" +%s 2>/dev/null || date +%s)
      ttl=$(jq -r --argjson floor "$FLOOR_SECONDS" '[.observations[]?.seconds] | if length >= 2 then ((add / length) | floor) else $floor end | [$floor, .] | max' "$state" 2>/dev/null || printf '%s' "$FLOOR_SECONDS")
      jq --arg key "$key" --argjson at "$now" --argjson deadline "$((now + ttl))" '.last_key=$key | .hit_at=$at | .deadline=$deadline' "$state" >"$state.tmp" 2>/dev/null && mv -f "$state.tmp" "$state"
    fi
  fi

  pct=0
  [[ "$input" -gt 0 ]] && pct=$((cached * 100 / input))
  [[ "$pct" -gt 100 ]] && pct=100
  ttl=$(jq -r '.deadline // 0' "$state" 2>/dev/null)
  if [[ "$cached" -gt 0 && "$ttl" =~ ^[0-9]+$ && "$ttl" -gt "$(date +%s)" ]]; then
    report "$pane" "🔥~$(fmt_clock "$ttl") ${pct}% ⇣$(fmt_tokens "$cached")"
  elif [[ "$cached" -gt 0 ]]; then
    report "$pane" "❄cold ${pct}% ⇣$(fmt_tokens "$cached")"
  else
    report "$pane" '❄cold 0% ⇣0'
  fi
}

while :; do
  while IFS=$'\t' read -r pane cwd; do
    [[ -n "$pane" && -n "$cwd" ]] && update_pane "$pane" "$cwd"
  done < <("$HERDR_BIN" pane list 2>/dev/null | jq -r '.result.panes[]? | select(.agent == "codex") | [.pane_id, .cwd] | @tsv' 2>/dev/null)
  sleep "$POLL_SECONDS"
done
