# Herdr agent orchestration playbook

How an agent running inside Herdr (`HERDR_ENV=1`) dispatches other agents into Herdr spaces, gives them work, and coordinates them. This is the primary reason the `herdr` skill exists.

## Mental model

You are one pane. Every other unit of work — a sub-agent, a dev server, a test run, a log tail — is another **pane** you create, address by id, drive with `run`/`send`, observe with `read`, and synchronize on with `wait`. Herdr gives you three placement scopes:

| Scope | Create with | Use when |
|-------|-------------|----------|
| Same tab (sibling pane) | `pane split --pane "$HERDR_PANE_ID"` or `agent start --tab "$HERDR_TAB_ID"` | tightly-coupled helper you watch live (server + its logs, a quick reviewer) |
| New tab, same workspace | `tab create` then split, or `agent start --workspace "$HERDR_WORKSPACE_ID"` | a parallel sub-task within the same project that deserves its own view |
| New workspace | `workspace create --cwd DIR` or `worktree create` | an independent job on another repo/branch; isolates cwd and git state |

Choose the **smallest** scope that keeps the work legible. Fan-out across workspaces when jobs are truly independent; keep them in tabs when you'll be reading them together.

## `agent start` vs `pane split` + `pane run`

- **`agent start <name> … -- <argv>`** when the process is a coding agent you want to *track as an agent*: it appears in `agent list` by `name`, is waitable via `wait agent-status`, readable/sendable by name, and directly attachable. Id at `result.agent.pane_id`. It targets a workspace/tab (`--workspace`, `--tab`, `--split`), **not** a specific `--pane`.
- **`pane split` + `pane run`** for servers, tests, shells, or any plain command. Id at `result.pane.pane_id`. `pane run` = text + Enter atomically. This pane's `agent_status` stays `unknown` unless a recognized agent runs in it.

Both are "spaces". The difference is whether Herdr's agent machinery (state rollup, `agent-status` waits, attach-by-name) applies.

## Core recipes

### 1. Spawn a sub-agent and hand it a task

```bash
J=$(herdr agent start reviewer --tab "$HERDR_TAB_ID" --split down --no-focus -- claude)
P=$(printf '%s' "$J" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["agent"]["pane_id"])')
herdr wait output "$P" --match ">" --timeout 15000        # wait for its prompt
herdr pane run "$P" "review test coverage in src/api/ and list the top 3 gaps"
herdr wait agent-status "$P" --status done --timeout 600000
herdr pane read "$P" --source recent --lines 150
```

### 2. Run a server + wait until ready + tail it

```bash
P=$(herdr pane split --pane "$HERDR_PANE_ID" --direction right --no-focus \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
herdr pane run "$P" "npm run dev"
herdr wait output "$P" --match "ready" --timeout 30000
herdr pane read "$P" --source recent-unwrapped --lines 40
```

### 3. Run tests in a sibling pane and inspect the result

```bash
P=$(herdr pane split --pane "$HERDR_PANE_ID" --direction down --no-focus \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
herdr pane run "$P" "cargo test"
herdr wait output "$P" --match "test result" --timeout 120000
herdr pane read "$P" --source recent-unwrapped --lines 60
```

### 4. Fan-out / fan-in — dispatch N agents, wait for all

```bash
# spec: "name|cwd|task" per line
JOBS=(
  "auth-fix|$HOME/repos/api|fix the failing auth tests in tests/auth"
  "docs|$HOME/repos/api|update the README API section to match src/routes"
  "perf|$HOME/repos/api|profile the slow /search endpoint and propose a fix"
)
PANES=()
for spec in "${JOBS[@]}"; do
  IFS='|' read -r name cwd task <<<"$spec"
  # each job gets its own workspace; id is at .result.workspace.workspace_id (an OBJECT, not the id)
  WS=$(herdr workspace create --cwd "$cwd" --label "$name" --no-focus \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["workspace"]["workspace_id"])')
  P=$(bin/herd.sh spawn "$name" --workspace "$WS" --cwd "$cwd" -- claude)   # prints the agent pane id
  herdr wait output "$P" --match ">" --timeout 15000
  herdr pane run "$P" "$task"
  PANES+=("$P")
done
# fan-in: block on each, collect output
for P in "${PANES[@]}"; do
  herdr wait agent-status "$P" --status done --timeout 900000 || echo "timeout/blocked: $P"
  echo "===== $P ====="; herdr pane read "$P" --source recent --lines 120
done
herdr notification show "fan-out complete" --body "${#PANES[@]} agents finished" --sound done
```

The bundled `bin/herd.sh` collapses the id-parsing and placement into `spawn` / `split` / `await` subcommands — prefer it over hand-rolling the `python3` one-liners.

### 5. Coordinate: react to a blocked agent

A `blocked` agent is waiting on a human/approval. Detect it, surface it, but do **not** blindly send input:

```bash
herdr wait agent-status "$P" --status blocked --timeout 600000 && {
  herdr notification show "agent needs input" --body "$P is blocked" --sound request
  herdr pane read "$P" --source detection --lines 30   # see exactly what it's asking
}
```

Screen-based `blocked` detection is strict; an unusual prompt may read `idle`. Confirm with `pane read --source detection` before deciding a pane is waiting.

### 6. Handoff between agents

Agent A produces something, agent B consumes it. Wait on A's `done`, read its output, feed a distilled prompt to B — pass artifacts via files, not by pasting large transcripts:

```bash
herdr wait agent-status "$A" --status done --timeout 900000
herdr pane run "$A" "write your findings to /tmp/findings-$A.md"
herdr wait output "$A" --match "written" --timeout 30000
herdr pane run "$B" "read /tmp/findings-$A.md and implement the top recommendation"
```

### 7. Worktree-per-agent (parallel work on the same repo, isolated branches)

```bash
WT=$(herdr worktree create --workspace "$HERDR_WORKSPACE_ID" --branch "worktree/agent-1" --no-focus --json \
     | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["workspace"]["workspace_id"])')
herdr agent start builder --workspace "$WT" --no-focus -- claude
# … drive it; when done, `worktree remove --workspace "$WT" --force` deletes the checkout (never the branch)
```

## Discipline for reliable orchestration

- **Re-resolve ids every step.** Ids compact when panes close. Read from the create/split/list JSON immediately before use; use `$HERDR_*_ID` only for yourself. Never cache a child's id across a phase where other panes may have closed — re-list if unsure.
- **Parse JSON, don't scrape.** `.result.pane.pane_id` for splits, `.result.agent.pane_id` for `agent start`. A wrong id sent to `pane close` kills the wrong pane.
- **Wait on the right signal.** `wait output` for "the process printed X" (servers, tests). `wait agent-status … done` for "the coding agent finished a turn". Don't `wait output` for an agent finishing — its UI is noisy; use the semantic state.
- **Give timeouts, handle exit 1.** Every `wait` can time out (exit `1`). Treat a timeout as "still working or stuck" — read the pane, don't assume failure.
- **Read `visible` on fresh panes.** A just-spawned pane's `recent`/`recent-unwrapped` buffer can be empty until output scrolls; `--source visible` gives an immediate snapshot. After a pane has produced output (e.g. post-`wait`), `recent-unwrapped` is the best source for logs.
- **Keep focus.** Always pass `--no-focus` when spawning; the human's focus shouldn't jump. Use `agent focus`/`workspace focus` deliberately only when you want to hand the human a pane.
- **Announce, don't spin.** On completion or a needed decision, `notification show` (with `--sound done`/`request`) rather than leaving the human to notice.
- **Clean up.** Close panes/worktrees you created once their output is captured, so ids stay legible and resources free. Confirm the id from fresh JSON before closing.
- **Upgrade detection when it matters.** For agents you orchestrate heavily, `herdr integration install <name>` swaps screen-guessing for authoritative lifecycle hooks — more reliable `agent-status` waits. Ask the user before installing.
