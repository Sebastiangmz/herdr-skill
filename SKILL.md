---
name: herdr-plus
description: "Operate the Herdr terminal workspace runtime from inside it — manage sessions, workspaces, tabs and panes, and (the main use) spawn, place, and coordinate sub-agents in Herdr spaces via the `herdr` CLI over the local socket. Use this whenever HERDR_ENV=1, or whenever the task involves splitting panes, creating workspaces/tabs, dispatching or fanning out multiple coding agents (claude, codex, pi, omp, hermes…) into separate Herdr panes and coordinating them, waiting for an agent to finish or become blocked, running a server/test in a sibling pane, or reading another pane's terminal output — even if the user only says 'run this in another pane', 'spin up an agent to do X', 'have an agent handle Y while I…', or 'watch that build/log'."
---

# herdr-plus

Herdr is a terminal workspace manager for AI coding agents: a background **server** owns real terminal processes, **clients** attach to render them, and a local **socket API** lets scripts and agents drive it. The `herdr` binary in `PATH` talks to that server. Verified against **herdr 0.7.0** (protocol 14).

This skill teaches you to control Herdr yourself — most importantly, to **spawn other agents into Herdr panes/tabs/workspaces, give them work, and coordinate them**. That orchestration playbook is the reason this skill exists; read [`references/orchestration.md`](references/orchestration.md) before running a real fan-out.

## First rule: are you inside Herdr?

Check `HERDR_ENV`. If it is **not** `1`, you are not in a Herdr-managed pane — do not try to control or inspect the focused Herdr UI, and **never run bare `herdr`** (nested launches are blocked by design). You can still drive a *remote* server via `HERDR_SOCKET_PATH`/`--session`, but the self-orchestration recipes below assume `HERDR_ENV=1`.

```bash
[ "$HERDR_ENV" = 1 ] || { echo "not inside herdr"; }
```

When inside, Herdr injects these into your process — this is how you know **who and where you are**:

| Var | Meaning |
|-----|---------|
| `HERDR_ENV` | `1` inside a managed pane |
| `HERDR_PANE_ID` | your pane id, e.g. `w5:p4` |
| `HERDR_TAB_ID` | your tab id, e.g. `w5:t2` |
| `HERDR_WORKSPACE_ID` | your workspace id, e.g. `w5` |
| `HERDR_SOCKET_PATH` | server socket (also the session selector) |

## Concept model

```
session ─▶ workspace ─▶ tab ─▶ pane ─▶ (agent)
(server    (per repo/    (view   (real
 namespace) task)         group)  terminal)
```

- **session** — server namespace. `herdr` attaches the default one; named sessions are separate runtimes with their own socket. Most work is the default session.
- **workspace** — project-level container (one per repo/task). Sidebar rolls agent state up per workspace.
- **tab** — a layout/subcontext inside a workspace (e.g. `agents`, `logs`, `server`).
- **pane** — a real terminal. Split right/down. **This is your "space" for another agent or process.**
- **agent** — a process Herdr recognizes in a pane. `agent_status ∈ {working, blocked, done, idle, unknown}`. State rolls up: a `blocked` agent turns its pane/tab/workspace blocked in the sidebar. **Verified: when an agent goes from `working` to `idle`, Herdr surfaces it as `done`** (finished-but-unviewed) until you view the pane — so fan-in on **`done`**, not `idle`. Records from `agent list`/`agent get` carry `agent` (the type, e.g. `omp`, `claude`) and, only when you named it via `agent start <name>`/`agent rename`, a `name`. **Detected agents have no `name`** — resolve/parse with `name` if present else `agent`. `agent list` is **global**: it includes the human's own agents in other workspaces; never treat those as yours.

## ⚠️ The id rule (most common failure)

Ids are **not durable and come in multiple forms**. Getting this wrong destroys the wrong pane. Verified facts:

- Canonical `workspace_id` can be a short `w5` **or** a long hex `w653d78f460db43`. Pane ids are `<workspace_id>:p<N>` (`w5:p4`), tabs `<workspace_id>:t<N>` (`w5:t2`).
- Each workspace also has a human-facing `number` (1, 2, 3…) shown in the sidebar. **`number` ≠ `workspace_id`.** Never build an id from `number`.
- Ids **compact** when things close: an old `w5:p3` may later be a different pane.

Therefore:

1. For **yourself**, use `$HERDR_PANE_ID` / `$HERDR_TAB_ID` / `$HERDR_WORKSPACE_ID`.
2. For **anything else**, re-read the id fresh from the JSON of `... list`, `... get`, `... create`, or `... split` right before you use it. Never guess or cache across steps.
3. Parse ids from JSON, don't eyeball them. Extraction paths differ by command:
   - `pane split` → `result.pane.pane_id`
   - `workspace create` → `result.workspace.workspace_id` (also `result.tab.tab_id`, `result.root_pane.pane_id` — all **objects**, a new workspace already has a root pane)
   - `tab create` → `result.tab.tab_id` (also `result.root_pane.pane_id`)
   - **`agent start` → `result.agent.pane_id`** (note: `.agent`, not `.pane`)

## ⚠️ Prefer explicit `--pane`, not `--current`

Verified: `herdr pane split --current …` fell back to the **UI-focused** pane (a different tab), not the calling pane. Always target your pane explicitly so the split lands where you expect:

```bash
herdr pane split --pane "$HERDR_PANE_ID" --direction down --no-focus   # ✔ lands in YOUR tab
```

## Command map (what you can drive)

Read-only/JSON commands are safe to run freely; process-launching and `close` commands mutate state.

| Area | Commands |
|------|----------|
| Status | `status [server\|client]`, `api schema [--json]`, `api snapshot` |
| Sessions | `session list/attach/stop/delete` |
| Workspaces | `workspace list/create/get/focus/rename/close` |
| Worktrees | `worktree list/create/open/remove` (git checkout as workspace) |
| Tabs | `tab list/create/get/focus/rename/close` |
| Panes | `pane list/get/split/run/read/send-text/send-keys/close/rename/move/swap/zoom/resize/focus/layout/process-info/report-agent/report-metadata` |
| Agents | `agent list/get/read/send/rename/focus/wait/attach/start/explain` |
| Waits | `wait output`, `wait agent-status` |
| Integrations | `integration install/uninstall/status` |
| Notify | `notification show` |

Full flags and semantics: [`references/cli-reference.md`](references/cli-reference.md). Raw socket methods, events, and report/metadata shapes: [`references/socket-api.md`](references/socket-api.md).

## Reading & waiting (the coordination primitives)

```bash
# what's on another pane's screen (prints text, not JSON)
herdr pane read <pane_id> --source recent --lines 80      # recent scrollback (wrapped)
herdr pane read <pane_id> --source recent-unwrapped       # best for logs
herdr pane read <pane_id> --source visible                # current viewport
herdr pane read <pane_id> --source detection              # bottom-buffer used for agent detection

# block until text appears (servers/builds/tests)
herdr wait output <pane_id> --match "ready on port 3000" --timeout 30000
herdr wait output <pane_id> --match "server.*ready" --regex --timeout 30000   # exit 1 on timeout

# block until a coding agent reaches a semantic state
herdr wait agent-status <target> --status done --timeout 120000
```

`wait output` matches against **unwrapped recent** text, so pane width won't break matches; inspect the same transcript with `pane read --source recent-unwrapped`.

**Verified nuance:** on a **freshly spawned** pane `--source recent`/`recent-unwrapped` can be empty until output has scrolled — use `--source visible` for an immediate snapshot, or (better) `wait output` for the text you expect *before* reading. Once a pane has produced output, `recent`/`recent-unwrapped` are reliable and best for logs.

## Orchestration playbook (spawn agents into spaces)

Two ways to create a space and put work in it:

- **`agent start`** — when the process **is** a coding agent you want to track, wait on, read, and attach to by name. It registers an agent target (shows in `agent list`, waitable by `agent-status`).
- **`pane split` + `pane run`** — for servers, tests, shells, or a plain command. `pane run` submits text **plus Enter** atomically; prefer it over `send-text` + `send-keys Enter`.

Place work in your own tab with `--tab "$HERDR_TAB_ID"`, or give it a fresh space with `--workspace`/a new workspace.

**Spawn a sub-agent and hand it a task (verified pattern):**

```bash
# 1) spawn a claude agent in a new pane in your tab, keep your focus
J=$(herdr agent start reviewer --tab "$HERDR_TAB_ID" --split down --no-focus -- claude)
P=$(printf '%s' "$J" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["agent"]["pane_id"])')

# 2) wait for its prompt, then send the task
herdr wait output "$P" --match ">" --timeout 15000
herdr pane run "$P" "review the test coverage in src/api/ and summarize gaps"

# 3) coordinate: block until it finishes, then read the result
herdr wait agent-status "$P" --status done --timeout 600000
herdr pane read "$P" --source recent --lines 120
```

**Fan-out / fan-in** (dispatch several, wait for all): see the loop in [`references/orchestration.md`](references/orchestration.md). The bundled helper does the id-parsing and placement for you:

```bash
# spawn an agent, print its pane id (parses agent.pane_id, places in your tab by default)
PANE=$(bin/herd.sh spawn reviewer -- claude)
# split your pane, run a command, print the new pane id (parses pane.pane_id)
PANE=$(bin/herd.sh split --direction down -- "npm run dev")
# wait for one or more targets to reach a status
bin/herd.sh await --status done --timeout 600000 "$PANE_A" "$PANE_B"
```

Run `bin/herd.sh help` for the full surface. The script is a thin, robust wrapper over the same CLI — it never invents ids and exits non-zero on any Herdr error.

## Signalling completion

Tell the human (or a watching orchestrator) when meaningful work lands, instead of polling silently:

```bash
herdr notification show "review done" --body "reviewer agent finished src/api" --sound done
```

## Safety rules

- Never run bare `herdr` inside a pane (nested launch blocked).
- Never `pane close` / `workspace close` an id you didn't just resolve from fresh JSON. `worktree remove` deletes a git checkout — treat as destructive.
- Screen-based `blocked` detection is deliberately strict; an unusual new agent prompt may read `idle`. Do **not** send input to another agent's pane on the assumption it's waiting unless you've confirmed via `pane read`.
- Installing an agent's integration (`herdr integration install <name>`) upgrades its state from screen-guessing to authoritative hooks — do this for agents you orchestrate heavily when the user asks.
- Prefer read-only introspection (`list`/`get`/`read`/`explain`) before any mutation.

## References

- [`references/cli-reference.md`](references/cli-reference.md) — every CLI command, flag, and read source.
- [`references/socket-api.md`](references/socket-api.md) — raw socket methods, event subscriptions, `report-agent`/`report-metadata`, layout export/apply.
- [`references/orchestration.md`](references/orchestration.md) — multi-agent dispatch strategies, fan-out/fan-in, handoff, when to use `agent start` vs `pane split`, worktree-per-agent.
- Upstream docs: <https://herdr.dev/docs/> · CLI <https://herdr.dev/docs/cli-reference/> · Socket API <https://herdr.dev/docs/socket-api/>
