#!/usr/bin/env bash
# herd.sh — thin, robust wrapper over the `herdr` CLI for agent orchestration.
# It never invents ids: it parses them from Herdr's JSON responses, places work
# in YOUR tab by default, and exits non-zero on any Herdr error.
#
# Usage:
#   herd.sh spawn <name> [--tab TAB] [--workspace WS] [--cwd DIR] [--split right|down] -- <argv...>
#       Start a coding agent as a Herdr agent target. Prints its pane_id.
#       Default placement: your tab ($HERDR_TAB_ID), split down, --no-focus.
#
#   herd.sh split [--pane PANE] [--direction right|down] [--cwd DIR] [-- <command>]
#       Split a pane (yours by default) and optionally run <command> in it.
#       Prints the new pane_id.
#
#   herd.sh await [--status done|idle|working|blocked] [--timeout MS] <target...>
#       Block until each target reaches --status (default done). Exit 1 if any timed out.
#
#   herd.sh read <target> [--source visible|recent|recent-unwrapped|detection] [--lines N]
#       Passthrough to `herdr pane read` (prints text).
#
#   herd.sh help
set -euo pipefail

die() { printf 'herd.sh: %s\n' "$*" >&2; exit 1; }

# Extract a dotted JSON path from stdin. Uses jq if available, else python3.
json_get() {
  local path="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -er "$path" 2>/dev/null || return 1
  else
    HERD_JQ_PATH="$path" python3 - <<'PY' 2>/dev/null || return 1
import sys, json, os
d = json.load(sys.stdin)
for k in os.environ["HERD_JQ_PATH"].lstrip(".").split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)
PY
  fi
}

# Fail loudly if a Herdr JSON response carried an error object.
assert_ok() {
  local json="$1"
  if printf '%s' "$json" | json_get '.error.message' >/dev/null 2>&1; then
    die "herdr error: $(printf '%s' "$json" | json_get '.error.message')"
  fi
}

need_env() { [ "${HERDR_ENV:-}" = 1 ] || die "not inside herdr (HERDR_ENV != 1)"; }

cmd_spawn() {
  need_env
  local name="" tab="" ws="" cwd="" split="down"
  [ $# -ge 1 ] || die "spawn: missing <name>"
  name="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --tab) tab="$2"; shift 2;;
      --workspace) ws="$2"; shift 2;;
      --cwd) cwd="$2"; shift 2;;
      --split) split="$2"; shift 2;;
      --) shift; break;;
      *) die "spawn: unknown flag '$1' (argv goes after --)";;
    esac
  done
  [ $# -ge 1 ] || die "spawn: missing '-- <argv...>' (the command to run as the agent)"
  # Default placement: your tab, unless a workspace/tab was requested.
  if [ -z "$tab" ] && [ -z "$ws" ]; then tab="$HERDR_TAB_ID"; fi
  local args=(agent start "$name" --split "$split" --no-focus)
  [ -n "$tab" ] && args+=(--tab "$tab")
  [ -n "$ws" ]  && args+=(--workspace "$ws")
  [ -n "$cwd" ] && args+=(--cwd "$cwd")
  args+=(--)
  local json; json="$(herdr "${args[@]}" "$@")"
  assert_ok "$json"
  printf '%s' "$json" | json_get '.result.agent.pane_id' || die "spawn: could not parse agent.pane_id from: $json"
}

cmd_split() {
  need_env
  local pane="$HERDR_PANE_ID" direction="down" cwd="" run_cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pane) pane="$2"; shift 2;;
      --direction) direction="$2"; shift 2;;
      --cwd) cwd="$2"; shift 2;;
      --) shift; run_cmd="$*"; break;;
      *) die "split: unknown flag '$1' (command goes after --)";;
    esac
  done
  local args=(pane split --pane "$pane" --direction "$direction" --no-focus)
  [ -n "$cwd" ] && args+=(--cwd "$cwd")
  local json; json="$(herdr "${args[@]}")"
  assert_ok "$json"
  local newid; newid="$(printf '%s' "$json" | json_get '.result.pane.pane_id')" || die "split: could not parse pane.pane_id from: $json"
  [ -n "$run_cmd" ] && herdr pane run "$newid" "$run_cmd"
  printf '%s\n' "$newid"
}

cmd_await() {
  need_env
  local status="done" timeout="600000" targets=() rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status="$2"; shift 2;;
      --timeout) timeout="$2"; shift 2;;
      -*) die "await: unknown flag '$1'";;
      *) targets+=("$1"); shift;;
    esac
  done
  [ ${#targets[@]} -ge 1 ] || die "await: missing target(s)"
  for t in "${targets[@]}"; do
    if herdr wait agent-status "$t" --status "$status" --timeout "$timeout" >/dev/null 2>&1; then
      printf 'ok    %s -> %s\n' "$t" "$status"
    else
      printf 'TIMEOUT %s (never reached %s)\n' "$t" "$status" >&2; rc=1
    fi
  done
  return $rc
}

cmd_read() {
  need_env
  [ $# -ge 1 ] || die "read: missing <target>"
  local t="$1"; shift
  herdr pane read "$t" "$@"
}

case "${1:-help}" in
  spawn) shift; cmd_spawn "$@";;
  split) shift; cmd_split "$@";;
  await) shift; cmd_await "$@";;
  read)  shift; cmd_read "$@";;
  help|-h|--help) awk 'NR>1{ if ($0 ~ /^#/){ sub(/^# ?/,""); print } else exit }' "$0";;
  *) die "unknown subcommand '$1' (try: spawn|split|await|read|help)";;
esac
