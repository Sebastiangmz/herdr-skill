#!/usr/bin/env bash
# End-to-end validation of the herdr skill: act as an orchestrator agent,
# fan out several agents into a NEW isolated workspace, coordinate them,
# then prove the user's existing runtime is untouched.
set -uo pipefail
SKILL="$(cd "$(dirname "$0")/.." && pwd)"   # repo root = the skill
HERD="$SKILL/bin/herd.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
jq_() { python3 -c "import sys,json;d=json.load(sys.stdin);$1"; }

echo "### 0. Preconditions"
[ "${HERDR_ENV:-}" = 1 ] && ok "running inside herdr (HERDR_ENV=1)" || no "not inside herdr"
BEFORE=$(herdr workspace list | jq_ 'print(" ".join(sorted(w["workspace_id"] for w in d["result"]["workspaces"])))')
echo "  existing workspaces: $BEFORE"

echo "### 1. Create isolated test workspace"
WS=$(herdr workspace create --cwd /tmp --label "herdr-skill-validation" --no-focus \
     | jq_ 'print(d["result"]["workspace"]["workspace_id"])')
[ -n "$WS" ] && ok "created workspace $WS" || { no "workspace create"; exit 1; }

echo "### 2. Fan-out: dispatch 3 worker agents into $WS"
declare -a NAMES=(alpha beta gamma) TASKS=("lint the api" "write docs" "profile search") PANES=()
for i in 0 1 2; do
  n=${NAMES[$i]}; t=${TASKS[$i]}
  P=$("$HERD" spawn "$n" --workspace "$WS" -- bash "$SKILL/test/sim-agent.sh" "$n" 3 "$t")
  if [ -n "$P" ]; then PANES+=("$P"); ok "spawned $n -> $P"; else no "spawn $n"; fi
done

echo "### 3. Assert placement + registration (records key on name|agent)"
for idx in "${!PANES[@]}"; do
  P=${PANES[$idx]}; n=${NAMES[$idx]}
  pws=$(herdr pane get "$P" | jq_ 'print(d["result"]["pane"]["workspace_id"])' 2>/dev/null)
  [ "$pws" = "$WS" ] && ok "$n pane in test workspace ($P in $pws)" || no "$n pane in wrong ws ($pws)"
done
# scope to OUR children in $WS; resolve label as name-or-agent
MINE=$(herdr agent list | WS="$WS" jq_ 'import os;ws=os.environ["WS"];print(" ".join(sorted((a.get("name") or a.get("agent")) for a in d["result"]["agents"] if a.get("workspace_id")==ws)))')
echo "  agents in $WS: $MINE"
for n in alpha beta gamma; do
  case " $MINE " in *" $n "*) ok "agent '$n' registered in $WS";; *) no "agent '$n' missing";; esac
done

echo "### 4. Fan-in: wait for each worker's completion marker, read result"
for idx in "${!PANES[@]}"; do
  P=${PANES[$idx]}; n=${NAMES[$idx]}
  if herdr wait output "$P" --match "TASK-DONE:$n" --timeout 15000 >/dev/null 2>&1; then
    ok "$n reached TASK-DONE (wait output)"
  else no "$n never signalled done"; fi
  line=""; for try in 1 2 3; do
    line=$(herdr pane read "$P" --source recent --lines 25 | grep "RESULT:" | tail -1)
    [ -n "$line" ] && break; sleep 1
  done
  [ -n "$line" ] && ok "read $n result: ${line#*RESULT: }" || no "could not read $n result"
done

echo "### 5. Semantic fan-in via herd.sh await --status done (idle rolls up to done)"
if "$HERD" await --status done --timeout 15000 "${PANES[@]}" >/dev/null 2>&1; then
  ok "all workers reached 'done' (herd.sh await)"
else no "herd.sh await done did not resolve for all"; fi

echo "### 6. Blocked-agent detection path"
BP=$("$HERD" spawn blocker --workspace "$WS" -- bash -c '
  herdr pane report-agent "$HERDR_PANE_ID" --source sim --agent blocker --state working >/dev/null 2>&1
  sleep 1
  echo "NEEDS-INPUT: approve deploy? [y/N]"
  herdr pane report-agent "$HERDR_PANE_ID" --source sim --agent blocker --state blocked --custom-status "awaiting approval" >/dev/null 2>&1
  sleep 40')
if herdr wait agent-status "$BP" --status blocked --timeout 12000 >/dev/null 2>&1; then
  ok "detected blocker as blocked (wait agent-status)"
  det=$(herdr pane read "$BP" --source detection --lines 10 | grep -i "NEEDS-INPUT" | tail -1)
  [ -n "$det" ] && ok "read what it is blocked on: ${det#*: }" || no "could not read blocked prompt"
else no "blocked state never observed"; fi

echo "### 7. Completion notification"
herdr notification show "validation complete" --body "orchestrated ${#PANES[@]} workers + 1 blocker in $WS" --sound done >/dev/null 2>&1 \
  && ok "notification shown" || no "notification failed"

echo "### 8. Teardown test workspace"
herdr workspace close "$WS" >/dev/null 2>&1 && ok "closed test workspace $WS" || no "could not close $WS"
sleep 2

echo "### 9. Assert user's runtime untouched"
AFTER=$(herdr workspace list | jq_ 'print(" ".join(sorted(w["workspace_id"] for w in d["result"]["workspaces"])))')
[ "$AFTER" = "$BEFORE" ] && ok "workspace set identical before/after" || no "workspace set changed! before=[$BEFORE] after=[$AFTER]"
LEFT=$(herdr agent list | WS="$WS" jq_ 'import os;ws=os.environ["WS"];print(sum(1 for a in d["result"]["agents"] if a.get("workspace_id")==ws))')
[ "$LEFT" = "0" ] && ok "no leftover agents in test workspace" || no "leftover agents in $WS: $LEFT"

echo
echo "======== RESULT: $PASS passed, $FAIL failed ========"
[ "$FAIL" = 0 ]
