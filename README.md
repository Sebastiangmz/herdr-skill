# herdr-plus

An agent skill that teaches AI coding agents to operate the [Herdr](https://herdr.dev) terminal workspace runtime — manage sessions, workspaces, tabs and panes, and (the main use) **spawn and coordinate sub-agents inside Herdr spaces** through the `herdr` CLI over its local socket.

It is a standard **[Agent Skill](https://agentskills.io)** (`SKILL.md` + optional `references/` and a `bin/` helper, with progressive disclosure). Agent Skills is an **open, cross-tool standard** — originated by Anthropic (Dec 2025), now an independent spec governed at [agentskills.io](https://agentskills.io) (Apache-2.0 / CC-BY-4.0). The same `SKILL.md` is read **without modification** by 20+ agents — Claude Code, OpenAI Codex CLI, Cursor, Gemini CLI, GitHub Copilot, Windsurf, Amp, OMP, and more — so this skill is portable, not tied to any one vendor.

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
install.sh                   agnostic installer (macOS/Linux/WSL): --target / --dir / --list
install.ps1                  agnostic installer (Windows PowerShell)
```

## Install

### One-line installer (recommended)

Download- and harness-agnostic. Pick your target; it fetches the skill and drops it in the right place.

**macOS / Linux / WSL:**

```bash
# interactive picker:
curl -fsSL https://raw.githubusercontent.com/Sebastiangmz/herdr-plus/main/install.sh | sh
# or non-interactive, choose a target:
curl -fsSL https://raw.githubusercontent.com/Sebastiangmz/herdr-plus/main/install.sh | sh -s -- --target claude --yes
```

**Windows (PowerShell):**

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Sebastiangmz/herdr-plus/main/install.ps1) } -Target claude -Yes"
```

Targets (`--target` / `-Target`): `claude` (`~/.claude/skills`), `claude-project` (`./.claude/skills`), `omp` (`~/.omp/agent/skills`), `cursor` (`./.cursor/skills`), `agents` (`./.agents/skills` — the vendor-neutral location Cursor/Codex and other Agent Skills tools read), `portable` (`~/.herdr-plus` + a paste-in instruction line, for the rare tool that still doesn't auto-load skills). For any other SKILL.md-compatible tool, point it at your skills dir with `--dir <path>` / `-Dir <path>`. Run with `--list` / `-List` to see them, `--help` for usage.

### Other ways

- **`skills` CLI (global, supported agents):** `npx skills add Sebastiangmz/herdr-plus --skill herdr-plus -g`
- **Manual clone:** copy this repo into your skills directory as `herdr-plus/` (so the tool resolves the `herdr-plus` skill from `SKILL.md` frontmatter).

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
