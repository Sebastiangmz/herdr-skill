# herdr-skill

An agent skill that teaches AI coding agents to operate the [Herdr](https://herdr.dev) terminal workspace runtime — manage sessions, workspaces, tabs and panes, and (the main use) **spawn and coordinate sub-agents inside Herdr spaces** through the `herdr` CLI over its local socket.

It follows the [Anthropic Agent Skills](https://www.anthropic.com/news/skills) format (progressive disclosure: a lean `SKILL.md` plus on-demand `references/` and an executable helper in `bin/`), so it drops into any harness that loads `SKILL.md` skills (Claude Code / OMP / the `skills` CLI).

## What it is for

An agent running *inside* Herdr (`HERDR_ENV=1`) can use this skill to act as an **orchestrator**: create an isolated workspace, fan out several agents (claude, codex, pi, omp, hermes…) into their own panes/tabs, hand each a task, wait on their state, read their output, and fan in — the workflow Herdr is built for.

## Layout

```
SKILL.md                     concept model, the id rule, safety, orchestration playbook, command map
references/
  cli-reference.md           every herdr CLI command, flag, read source, and JSON extraction cheat-sheet
  socket-api.md              raw socket methods, event subscriptions, report-agent/metadata, layout
  orchestration.md           multi-agent dispatch strategies, fan-out/fan-in, handoff, worktree-per-agent
bin/herd.sh                  thin wrapper: spawn | split | await | read (parses ids from JSON, never guesses)
test/
  validate.sh                end-to-end validation: orchestrates agents in an isolated workspace, asserts 24 checks
  sim-agent.sh               a stand-in agent used by the validation
```

## Install

- **OMP / directory-based loaders:** copy this repo into your skills directory as `herdr/` (so `skill://herdr` resolves). The skill name comes from the `name:` field in `SKILL.md` frontmatter.
- **`skills` CLI (global):** `npx skills add Sebastiangmz/herdr-skill --skill herdr -g`
- **Manual:** paste `SKILL.md` into your agent's global instructions and keep `references/` + `bin/` alongside.

## Verified

Built and validated live against **herdr 0.7.0** (protocol 14) from inside a Herdr pane. `test/validate.sh` runs the full orchestration flow in a throwaway workspace and asserts placement, registration, output/state coordination, blocked-agent detection, notification, teardown, and that the host runtime is left untouched — 24/24 checks pass.

```bash
# run from inside a Herdr pane (HERDR_ENV=1):
bash test/validate.sh
```

## Notes on Herdr's model (learned the hard way, encoded in the skill)

- Ids are **not durable** and come in multiple forms (`w5` vs long hex; the sidebar `number` ≠ `workspace_id`). Always re-read ids from JSON; use `$HERDR_*_ID` for self.
- `pane split` id is at `result.pane.pane_id`; **`agent start` id is at `result.agent.pane_id`**; `workspace create` returns objects (`result.workspace.workspace_id`, …).
- Prefer explicit `--pane "$HERDR_PANE_ID"` over `--current`.
- A worker going `working → idle` surfaces as `done` — fan in on `done`.
- `agent list` is global and records key on `agent` (+ optional `name`).

## License

MIT — see [LICENSE](LICENSE).

Herdr itself is a separate project by [@ogulcancelik](https://github.com/ogulcancelik); this repo is an independent skill for driving it. Upstream docs: <https://herdr.dev/docs/>.
