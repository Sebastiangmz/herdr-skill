#!/usr/bin/env bash
# sim-agent.sh <name> <seconds> <task>
# A stand-in coding agent: reports semantic state via herdr, does "work",
# prints a completion marker, then goes idle. Faithful to the real agent
# lifecycle (working -> ... -> idle/done) that integrations drive.
name="${1:-agent}"; secs="${2:-3}"; task="${3:-noop}"
rep() { herdr pane report-agent "$HERDR_PANE_ID" --source sim --agent "$name" --state "$1" --custom-status "${2:-}" >/dev/null 2>&1 || true; }
rep working "starting"
echo "[$name] START task=$task pane=$HERDR_PANE_ID ws=$HERDR_WORKSPACE_ID"
for i in $(seq 1 "$secs"); do echo "[$name] working $i/$secs"; sleep 1; done
echo "[$name] RESULT: completed '$task'"
echo "TASK-DONE:$name"
rep idle "done"
# keep the pane alive briefly so the orchestrator can read final state
sleep 20
