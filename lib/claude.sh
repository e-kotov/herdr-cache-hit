#!/usr/bin/env bash

claude_transcript_path() {
  local session_id=$1 cwd=${2:-} supplied=${3:-} root project
  if [[ -n "$supplied" && -f "$supplied" ]]; then printf '%s\n' "$supplied"; return 0; fi
  [[ -n "$cwd" && -n "$session_id" ]] || return 1
  root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  project=${cwd//[^A-Za-z0-9]/-}
  supplied="$root/projects/$project/$session_id.jsonl"
  [[ -f "$supplied" ]] && printf '%s\n' "$supplied" || return 1
}

if command -v tac >/dev/null 2>&1; then
  rev_lines() { tac; }
else
  rev_lines() { tail -r; }
fi

claude_latest_usage() {
  local path=$1 session_id=$2
  (tail -n 500 "$path" 2>/dev/null; echo "") 2>/dev/null | rev_lines 2>/dev/null | jq -Rrn --arg sid "$session_id" '
    first(inputs
      | fromjson?
      | select(type == "object")
      | (.sessionId // .session_id // .conversation_id // .conversationId // null) as $embedded
      | select($embedded == null or $embedded == $sid)
      | (.message.usage // .usage // {}) as $u
      | select($u.cache_read_input_tokens != null)
      | select((($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + (($u.cache_creation // {}).ephemeral_5m_input_tokens // 0) + (($u.cache_creation // {}).ephemeral_1h_input_tokens // 0)) > 0)
      | {ts:(.timestamp // .created_at // .createdAt // .message.timestamp // ""),
         input:($u.input_tokens // null), read:($u.cache_read_input_tokens // null),
         write5m:((($u.cache_creation // {}).ephemeral_5m_input_tokens) // 0),
         write1h:((($u.cache_creation // {}).ephemeral_1h_input_tokens) // 0),
         write:(($u.cache_creation_input_tokens // ((((($u.cache_creation // {}).ephemeral_5m_input_tokens) // 0) + ((($u.cache_creation // {}).ephemeral_1h_input_tokens) // 0)))) // null),
         model:(.message.model // .model // ""),
         provider:(.provider // .model_provider // "anthropic"), source:""}
      | select((.ts|type)=="string" and (.ts|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")))
      | select((.input|type)=="number" and .input >= 0 and (.input|floor)==.input)
      | select((.read|type)=="number" and .read >= 0 and (.read|floor)==.read)
      | select((.write|type)=="number" and .write >= 0 and (.write|floor)==.write)
      | select((.model|type)=="string" and (.provider|type)=="string")
    ) | [.ts,.input,.read,.write,.write5m,.write1h,.model,.provider] | @tsv' 2>/dev/null
}

claude_usage() {
  local session_id=$1 cwd=${2:-} supplied=${3:-} path record ts input read write model provider
  path=$(claude_transcript_path "$session_id" "$cwd" "$supplied") || return 1
  record=$(claude_latest_usage "$path" "$session_id") || return 1
  [[ -n "$record" ]] || return 1
  IFS=$'\t' read -r ts input read write write5m write1h model provider <<<"$record"
  printf 'claude\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$session_id" "$ts" "$input" "$read" "$write" "$write5m" "$write1h" "$model" "$provider" "$path"
}
