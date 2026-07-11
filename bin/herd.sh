#!/usr/bin/env bash
# herd.sh — thin, robust wrapper over the `herdr` CLI for agent orchestration.
# It never invents ids: it parses them from Herdr's JSON responses, places work
# in YOUR tab by default, and exits non-zero on any Herdr error.
#
# LAYOUT DISCIPLINE (enforced automatically — see SKILL.md "Layout discipline"):
#   * Split direction ALTERNATES vertical -> horizontal -> vertical ... so panes
#     tile into a grid instead of one long strip. Pass --split/--direction to
#     override for a single call.
#   * At most HERD_MAX_PANES panes per tab (default 4 = a 2x2 grid). When a tab
#     is full, the next space is created in a NEW tab of the same workspace
#     automatically (a notice is printed to stderr). Set HERD_MAX_PANES to tune.
#
# Usage:
#   herd.sh spawn <name> [--tab TAB] [--workspace WS] [--cwd DIR] [--split right|down] -- <argv...>
#       Start a coding agent as a Herdr agent target. Prints its pane_id.
#       Default placement: your tab ($HERDR_TAB_ID), auto direction, --no-focus.
#
#   herd.sh split [--pane PANE] [--direction right|down] [--cwd DIR] [-- <command>]
#       Split a pane (yours by default) and optionally run <command> in it.
#       Prints the new pane_id. Honors the same cap + alternation rules.
#
#   herd.sh await [--status done|idle|working|blocked] [--timeout MS] <target...>
#       Block until each target reaches --status (default done). Exit 1 if any timed out.
#
#   herd.sh read <target> [--source visible|recent|recent-unwrapped|detection] [--lines N]
#       Passthrough to `herdr pane read` (prints text).
#
#   herd.sh help
set -euo pipefail

MAX_PANES="${HERD_MAX_PANES:-4}"

die() { printf 'herd.sh: %s\n' "$*" >&2; exit 1; }
note() { printf 'herd.sh: %s\n' "$*" >&2; }

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

# --- layout helpers -------------------------------------------------------

# workspace_id is the prefix of any tab/pane id, before the first ':'.
ws_of() { printf '%s' "${1%%:*}"; }

ws_active_tab() {
  local ws="$1" json; json="$(herdr workspace get "$ws")"; assert_ok "$json"
  printf '%s' "$json" | json_get '.result.workspace.active_tab_id' || die "cannot read active_tab_id for $ws"
}

tab_pane_count() {
  local tab="$1" json; json="$(herdr tab get "$tab")"; assert_ok "$json"
  printf '%s' "$json" | json_get '.result.tab.pane_count' || die "cannot read pane_count for $tab"
}

pane_tab() {
  local pane="$1" json; json="$(herdr pane get "$pane")"; assert_ok "$json"
  printf '%s' "$json" | json_get '.result.pane.tab_id' || die "cannot read tab_id for $pane"
}

# Create a new tab in a workspace; echo "<tab_id> <root_pane_id>".
new_tab() {
  local ws="$1" json; json="$(herdr tab create --workspace "$ws" --no-focus)"; assert_ok "$json"
  local t r
  t="$(printf '%s' "$json" | json_get '.result.tab.tab_id')" || die "new_tab: no tab_id"
  r="$(printf '%s' "$json" | json_get '.result.root_pane.pane_id')" || r=""
  printf '%s %s\n' "$t" "$r"
}

# Alternating split direction from the CURRENT pane count of the target tab:
#   odd count  -> right (a vertical divider: side-by-side columns)
#   even count -> down  (a horizontal divider: stacked rows)
# Starting from a fresh tab (1 root pane) this yields vertical, horizontal,
# vertical ... exactly the requested tiling pattern.
auto_dir() { [ $(( $1 % 2 )) -eq 1 ] && echo right || echo down; }

# Given a desired target tab, enforce the per-tab cap. Echoes "<tab> <count>":
# the tab to use (possibly a freshly created one) and its pane count BEFORE
# placement, so the caller can derive the alternating split direction.
place_tab() {
  local tab="$1" ws n
  ws="$(ws_of "$tab")"
  n="$(tab_pane_count "$tab")"
  if [ "$n" -ge "$MAX_PANES" ]; then
    local created; created="$(new_tab "$ws")"
    tab="${created%% *}"
    note "tab full (${MAX_PANES} panes) -> spilled into new tab $tab"
    n="$(tab_pane_count "$tab")"
  fi
  printf '%s %s\n' "$tab" "$n"        # echo tab + pane-count-before (no globals: runs in a subshell)
}

# --- subcommands ----------------------------------------------------------

cmd_spawn() {
  need_env
  local name="" tab="" ws="" cwd="" split=""
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

  # Resolve the concrete target tab so we can count panes and enforce the cap.
  if [ -n "$tab" ]; then
    :
  elif [ -n "$ws" ]; then
    tab="$(ws_active_tab "$ws")"
  else
    tab="$HERDR_TAB_ID"
  fi
  local placed; placed="$(place_tab "$tab")"      # may spill into a new tab
  tab="${placed%% *}"; local cnt="${placed##* }"
  [ -n "$split" ] || split="$(auto_dir "$cnt")"

  local args=(agent start "$name" --tab "$tab" --split "$split" --no-focus)
  [ -n "$cwd" ] && args+=(--cwd "$cwd")
  args+=(--)
  local json; json="$(herdr "${args[@]}" "$@")"
  assert_ok "$json"
  printf '%s' "$json" | json_get '.result.agent.pane_id' || die "spawn: could not parse agent.pane_id from: $json"
}

cmd_split() {
  need_env
  local pane="$HERDR_PANE_ID" direction="" cwd="" run_cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pane) pane="$2"; shift 2;;
      --direction) direction="$2"; shift 2;;
      --cwd) cwd="$2"; shift 2;;
      --) shift; run_cmd="$*"; break;;
      *) die "split: unknown flag '$1' (command goes after --)";;
    esac
  done

  # Enforce the per-tab cap on the pane's own tab; spill to a new tab if full.
  local tab newid; tab="$(pane_tab "$pane")"
  local before; before="$(tab_pane_count "$tab")"
  if [ "$before" -ge "$MAX_PANES" ]; then
    local created; created="$(new_tab "$(ws_of "$tab")")"
    local newtab rootpane; newtab="${created%% *}"; rootpane="${created##* }"
    note "tab full (${MAX_PANES} panes) -> spilled into new tab $newtab"
    newid="$rootpane"                              # run in the new tab's root pane
    [ -n "$run_cmd" ] && herdr pane run "$newid" "$run_cmd"
    printf '%s\n' "$newid"
    return 0
  fi
  [ -n "$direction" ] || direction="$(auto_dir "$before")"

  local args=(pane split --pane "$pane" --direction "$direction" --no-focus)
  [ -n "$cwd" ] && args+=(--cwd "$cwd")
  local json; json="$(herdr "${args[@]}")"
  assert_ok "$json"
  newid="$(printf '%s' "$json" | json_get '.result.pane.pane_id')" || die "split: could not parse pane.pane_id from: $json"
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
