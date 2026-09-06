#!/usr/bin/env bash
state_path() { printf '%s/state-%s.json\n' "$STATE_DIR" "${1//[^A-Za-z0-9_.-]/_}"; }
valid_state() { jq -e 'type == "object" and (.observations | type == "array") and ((.active == null) or ((.active | type) == "object" and ([.active.agent,.active.session_id,.active.model,.active.provider,.active.signature] | all(type == "string")) and (.active.hit_at | type == "number") and (.active.deadline | type == "number")))' "$1" >/dev/null 2>&1; }
load_state() {
  local path=$1 tmp
  if [[ ! -s "$path" ]] || ! valid_state "$path"; then
    tmp=$(mktemp "$STATE_DIR/state.XXXXXX") || return 1; printf '%s\n' '{"active":null,"observations":[]}' >"$tmp"; atomic_install "$tmp" "$path"
  fi
}
update_pane() {
  local pane=$1 agent session_id cwd supplied record state now record_epoch ttl_floor
  if [[ $# -eq 2 ]]; then agent=codex; session_id=$2; cwd=""; supplied=""; else agent=$2; session_id=$3; cwd=${4:-}; supplied=${5:-}; fi
  config_agent_enabled "$agent" || { clear_pane "$pane" "$agent"; return 0; }
  case "$agent" in
    codex) record=$(codex_usage "$session_id" 2>/dev/null) ;;
    agy) record=$(agy_usage "$session_id" "$supplied" 2>/dev/null) ;;
    claude) record=$(claude_usage "$session_id" "$cwd" "$supplied" 2>/dev/null) ;;
    *) clear_pane "$pane" "$agent"; return 0 ;;
  esac
  if [[ -z "$record" ]]; then
    if [[ "$agent" == agy ]]; then
      report_pane "$pane" "$agent" '❄cold' "$DISPLAY_TTL_MS" || true
    else
      clear_pane "$pane" "$agent"
    fi
    return 0
  fi
  local rec_agent rec_sid ts input read write write5m write1h model provider source_path source_deadline
  IFS=$'\t' read -r rec_agent rec_sid ts input read write write5m write1h model provider source_path source_deadline <<<"$record"
  : "$source_path"
  [[ "$rec_agent" == "$agent" && "$rec_sid" == "$session_id" ]] || { clear_pane "$pane" "$agent"; return 0; }
  record_epoch=$(parse_timestamp "$ts") || { clear_pane "$pane" "$agent"; return 0; }
  state=$(state_path "$pane"); load_state "$state" || return 1; now=$(date +%s)
  local signature; signature="$agent|$session_id|$model|$provider|$input|$read|$write|$write5m|$write1h"
  ttl_floor=$FLOOR_SECONDS
  if [[ "$agent" == claude ]]; then
    if [[ "$write1h" -gt 0 ]]; then ttl_floor=3600
    elif [[ "$write5m" -gt 0 ]]; then ttl_floor=300
    else ttl_floor=3600
    fi
  fi
  if [[ "$read" -eq 0 && "$write" -eq 0 ]]; then
    jq --arg sig "$signature" --arg agent "$agent" --arg sid "$session_id" --arg model "$model" --arg provider "$provider" --argjson at "$record_epoch" '
      if (.active != null and .active.agent == $agent and .active.session_id == $sid and .active.model == $model and .active.provider == $provider)
      then .observations=((.observations + [{seconds:(($at-.active.hit_at)|if . < 0 then 0 else . end),agent:$agent,session_id:$sid,model:$model,provider:$provider}])|. [-20:]) else . end | .active=null' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
  else
    jq --arg sig "$signature" --arg agent "$agent" --arg sid "$session_id" --arg model "$model" --arg provider "$provider" --argjson at "$record_epoch" --argjson floor "$ttl_floor" '
      if (.active == null or .active.agent != $agent or .active.session_id != $sid or .active.model != $model or .active.provider != $provider or .active.signature != $sig)
      then (.observations|map(select(.agent==$agent and .session_id==$sid and .model==$model and .provider==$provider)|.seconds)|if length>=2 then (add/length|floor) else $floor end) as $ttl | .active={agent:$agent,session_id:$sid,model:$model,provider:$provider,signature:$sig,hit_at:$at,deadline:($at+$ttl)} else . end' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
  fi
  if [[ "$agent" == agy && "$source_deadline" =~ ^[0-9]+$ && "$source_deadline" -gt 0 ]]; then
    jq --arg agent "$agent" --arg sid "$session_id" --argjson deadline "$source_deadline" 'if .active != null and .active.agent == $agent and .active.session_id == $sid then .active.deadline=$deadline else . end' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
  fi
  local deadline pct total
  deadline=$(jq -r '.active.deadline // 0' "$state" 2>/dev/null || printf 0)
  local show_deadline show_read show_write show_percentage show_model read_text write_text model_text deadline_text
  show_deadline=$(config_bool "$agent" show_deadline true)
  show_read=$(config_bool "$agent" show_read_tokens true)
  show_write=$(config_bool "$agent" show_write_tokens false)
  show_percentage=$(config_bool "$agent" show_percentage true)
  show_model=$(config_bool "$agent" show_model false)
  deadline_text=""
  [[ "$show_deadline" == true && "$deadline" =~ ^[0-9]+$ && "$deadline" -gt "$now" ]] && deadline_text="~$(fmt_clock "$deadline")"
  read_text=""; write_text=""
  [[ "$show_read" == true ]] && read_text="⇣$(fmt_tokens "$read")"
  [[ "$show_write" == true ]] && write_text="⇡$(fmt_tokens "$write")"
  model_text=""; [[ "$show_model" == true && -n "$model" ]] && model_text="$model"
  if [[ "$agent" == codex ]]; then
    pct=0; [[ "$input" -gt 0 ]] && pct=$((read*100/input)); [[ "$pct" -gt 100 ]] && pct=100
    local pct_text; pct_text=""; [[ "$show_percentage" == true ]] && pct_text="${pct}%"
    if [[ "$read" -gt 0 && -n "$deadline_text" ]]; then report_pane "$pane" "$agent" "🔥$deadline_text $pct_text $read_text $model_text" "$(( (deadline-now)*1000 ))" || true
    elif [[ "$read" -gt 0 ]]; then report_pane "$pane" "$agent" "❄cold $pct_text $read_text $model_text" "$DISPLAY_TTL_MS" || true
    else report_pane "$pane" "$agent" "❄cold ${pct_text:-} $read_text $model_text" "$DISPLAY_TTL_MS" || true; fi
  else
    total=$((input + read + write)); pct=0; [[ "$total" -gt 0 ]] && pct=$((read*100/total)); [[ "$pct" -gt 100 ]] && pct=100
    pct_text=""; [[ "$show_percentage" == true ]] && pct_text="${pct}%"
    if [[ "$total" -gt 0 && -n "$deadline_text" ]]; then
      report_pane "$pane" "$agent" "🔥$deadline_text $pct_text $read_text $write_text $model_text" "$(( (deadline-now)*1000 ))" || true
    elif [[ "$total" -gt 0 ]]; then report_pane "$pane" "$agent" "❄cold $pct_text $read_text $write_text $model_text" "$DISPLAY_TTL_MS" || true
    else report_pane "$pane" "$agent" "❄cold $pct_text $read_text $write_text $model_text" "$DISPLAY_TTL_MS" || true; fi
  fi
}
