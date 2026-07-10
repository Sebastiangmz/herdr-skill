# Herdr CLI reference

Complete `herdr` command surface. The CLI talks to the running server over the same local socket used by the raw API. Most commands print JSON on success; `pane read` / `agent read` print text. Verified against herdr 0.7.0 (protocol 14). Upstream: <https://herdr.dev/docs/cli-reference/>.

## Contents
- [Launch & status](#launch--status)
- [Server](#server)
- [Sessions](#sessions)
- [Workspaces](#workspaces)
- [Worktrees](#worktrees)
- [Tabs](#tabs)
- [Panes](#panes)
- [Agents](#agents)
- [Direct attach](#direct-terminal--agent-attach)
- [Waits](#waits)
- [Integrations](#integrations)
- [Plugins](#plugins)
- [Notifications](#notifications)
- [Read sources](#read-sources)
- [Environment variables](#environment-variables)
- [JSON extraction cheat-sheet](#json-extraction-cheat-sheet)

## Launch & status

```
herdr                          # launch or attach to the default session
herdr --session work           # launch or attach to a named session
herdr --remote HOST            # attach through SSH, local keybindings
herdr --remote HOST --remote-keybindings server
herdr --remote HOST --handoff
herdr --no-session             # single-process escape hatch
herdr --default-config         # print default config
herdr update [--handoff]       # install from configured channel
herdr channel show|set stable|preview
herdr --version
herdr status | status server | status client
herdr api schema [--json] [--output PATH]
herdr api snapshot             # live session.snapshot as JSON (bootstrap)
herdr completion zsh|bash|fish|powershell|elvish
```

Never run bare `herdr` inside a pane (`HERDR_ENV=1`) — nested launches are blocked.

## Server

```
herdr server                       # run headless server explicitly (service setups)
herdr server stop                  # stop everything
herdr server reload-config         # apply reloadable settings without restarting panes
herdr server agent-manifests [--json]
herdr server update-agent-manifests [--json]   # fetch+reload remote detection manifests
herdr server reload-agent-manifests            # reload after editing a local override
```

## Sessions

```
herdr session list [--json]
herdr session attach <name>
herdr session stop <name> [--json]     # use "default" to stop the default session
herdr session delete <name> [--json]
```

Session resolution order: `--session NAME` → `HERDR_SOCKET_PATH` → `HERDR_SESSION=NAME` → default. Sockets: `~/.config/herdr/herdr.sock`, named `~/.config/herdr/sessions/<name>/herdr.sock`.

## Workspaces

```
herdr workspace list
herdr workspace create [--cwd PATH] [--label TEXT] [--env KEY=VALUE] [--focus|--no-focus]
herdr workspace get <workspace_id>
herdr workspace focus <workspace_id>
herdr workspace rename <workspace_id> <label>
herdr workspace close <workspace_id>       # closes Herdr state only (not git worktrees)
```

`create` returns three **objects**: `result.workspace` (id at `.workspace_id`), `result.tab` (`.tab_id`), and `result.root_pane` (`.pane_id`) — a new workspace already has one root pane. `list`/`get` records include `workspace_id` (canonical — short `w5` or long hex), `number` (sidebar only), `label`, `active_tab_id`, `agent_status`, `pane_count`, `tab_count`, and optional `worktree` provenance.

## Worktrees

Git checkouts managed as Herdr workspaces.

```
herdr worktree list   [--workspace ID | --cwd PATH] [--json]
herdr worktree create [--workspace ID | --cwd PATH] [--branch NAME] [--base REF] [--path PATH] [--label TEXT] [--focus|--no-focus] [--json]
herdr worktree open   [--workspace ID | --cwd PATH] (--path PATH | --branch NAME) [--label TEXT] [--focus|--no-focus] [--json]
herdr worktree remove --workspace ID [--force] [--json]
```

`create`: if `--branch` names an existing local branch it is checked out, else created from `--base`/`HEAD`; without `--path` the checkout goes under `<worktrees.directory>/<repo>/<branch-slug>`. `remove` runs `git worktree remove` (needs `--force` on a dirty tree), **never deletes the branch**. `worktree remove` is the explicit checkout-deletion path; `workspace close` only drops Herdr state.

## Tabs

```
herdr tab list [--workspace <workspace_id>]
herdr tab create [--workspace ID] [--cwd PATH] [--label TEXT] [--env KEY=VALUE] [--focus|--no-focus]
herdr tab get <tab_id>
herdr tab focus <tab_id>
herdr tab rename <tab_id> <label>
herdr tab close <tab_id>
```

`create` returns objects `result.tab` (id at `.tab_id`) and `result.root_pane` (`.pane_id`). Without `--label`, keeps the numbered default name.

## Panes

```
herdr pane list [--workspace <workspace_id>]    # NOTE: without --workspace it does NOT scope to your workspace
herdr pane current [--pane ID|--current]
herdr pane get <pane_id>
herdr pane layout [--pane ID|--current]
herdr pane process-info [--pane ID|--current]   # shell pid, foreground pgid, argv/cwd when platform exposes it
herdr pane neighbor --direction left|right|up|down [--pane ID|--current]
herdr pane edges [--pane ID|--current]
herdr pane focus --direction left|right|up|down [--pane ID|--current]
herdr pane resize --direction left|right|up|down [--amount FLOAT] [--pane ID|--current]
herdr pane zoom [<pane_id>|--pane ID|--current] [--toggle|--on|--off]
herdr pane rename <pane_id> <label>|--clear
herdr pane split [<pane_id>|--pane ID|--current] --direction right|down [--ratio FLOAT] [--cwd PATH] [--env KEY=VALUE] [--focus|--no-focus]
herdr pane swap --direction left|right|up|down [--pane ID|--current]
herdr pane swap --source-pane ID --target-pane ID
herdr pane move <pane_id> --tab <tab_id> --split right|down [--target-pane ID] [--ratio FLOAT] [--focus|--no-focus]
herdr pane move <pane_id> --new-tab [--workspace ID] [--label TEXT] [--focus|--no-focus]
herdr pane move <pane_id> --new-workspace [--label TEXT] [--tab-label TEXT] [--focus|--no-focus]
herdr pane close <pane_id>
```

Read output / send input:

```
herdr pane read <pane_id> [--source visible|recent|recent-unwrapped|detection] [--lines N] [--ansi]
herdr pane send-text <pane_id> <text>          # no Enter
herdr pane send-keys <pane_id> <key> [key...]  # key-combo syntax below
herdr pane run  <pane_id> <command>            # text + Enter, atomic — prefer for commands
```

Key-combo syntax for `send-keys` / `send-input`: printable keys (`a`), special keys (`enter`, `tab`, `esc`, `backspace`, `left`/`right`/`up`/`down`), modifier chords (`ctrl+h`, `control+j`, `alt+x`, `shift+tab`), function keys (`f1`), named punctuation (`minus`, `plus`, `backtick`). Legacy `C-c`/`c-c` alias `ctrl+c`. **Does not** accept `prefix+` binding strings.

`--pane ID` / `--current` / omitted target: an explicit id or `--pane ID` targets that pane; `--current` uses the calling pane's `HERDR_PANE_ID`; omitted uses the UI-focused pane. **Prefer explicit `--pane "$HERDR_PANE_ID"`** — `--current` has been observed to fall back to the UI-focused pane in some harnesses.

Report custom state from hooks (see socket-api.md for full semantics):

```
herdr pane report-agent    <pane_id> --source ID --agent LABEL --state idle|working|blocked|unknown [--message TEXT] [--custom-status TEXT] [--seq N] [--agent-session-id ID] [--agent-session-path PATH]
herdr pane report-metadata <pane_id> --source ID [--agent LABEL] [--applies-to-source ID] [--title TEXT|--clear-title] [--display-agent TEXT|--clear-display-agent] [--custom-status TEXT|--clear-custom-status] [--state-label STATUS=TEXT] [--clear-state-labels] [--seq N] [--ttl-ms N]
```

## Agents

```
herdr agent list
herdr agent get   <target>
herdr agent read  <target> [--source visible|recent|recent-unwrapped|detection] [--lines N] [--format text|ansi] [--ansi]
herdr agent send  <target> <text>                 # writes literal text to the stream
herdr agent rename <target> <name>|--clear
herdr agent focus <target>
herdr agent wait  <target> --status idle|working|blocked|unknown [--timeout MS]
herdr agent attach <target> [--takeover]
herdr agent start <name> [--cwd PATH] [--workspace ID] [--tab ID] [--split right|down] [--env KEY=VALUE] [--focus|--no-focus] -- <argv...>
herdr agent explain <target> [--json|--verbose]
herdr agent explain --file PATH --agent LABEL [--json|--verbose]
```

- **`agent start` returns the id at `result.agent.pane_id`** (not `result.pane`). The started target appears in `agent list` by `name` even for non-recognized processes (verified with `-- bash`).
- Targets accept: terminal IDs, unique agent names, detected/reported labels, legacy pane IDs. Names/labels are identities; terminal/pane IDs are escape hatches.
- **Record fields (verified):** `agent list`/`agent get` records carry `agent` (type, e.g. `omp`, `delta`) and a `name` **only** when set via `agent start <name>`/`agent rename`. Detected agents (e.g. a running `omp`) have `agent` but no `name` (parse with `name` else `agent`). Records also expose `agent_status`, `custom_status`, `pane_id`/`tab_id`/`workspace_id`, `screen_detection_skipped` (true under a full lifecycle authority). `agent list` is **global** across workspaces — filter by `workspace_id` to scope to your own children.
- **`idle` surfaces as `done` (verified):** an agent transitioning `working → idle` is reported as `agent_status: done` (finished-but-unviewed) until its pane is viewed. Fan-in with `wait agent-status … --status done`, not `idle`.
- `agent get/focus/wait/attach` require the resolved terminal to have agent identity; `agent rename` can assign it.
- Use `agent …` when a terminal is meant to be an agent target; use `pane …` for servers/tests/shells.
- `agent explain` classifies the bottom-buffer detection snapshot in the running server (reflects the live manifest cache). Use `--file PATH --agent LABEL` for a saved fixture. `--verbose` adds evidence flags, remote/override status, and the full evaluated-rule list; `--json` for tooling.

## Direct terminal / agent attach

```
herdr agent attach <target> [--takeover]
herdr terminal attach <terminal_id> [--takeover]
herdr terminal session control <target> [--takeover] [--cols N] [--rows N]   # writable live stream (JSON on stdin)
herdr terminal session observe <target> [--cols N] [--rows N]                # read-only live stream
herdr terminal title set <title> | herdr terminal title clear
```

Detach from a direct attach with `ctrl+b q`; send a literal `ctrl+b` with `ctrl+b ctrl+b`. One controller owns input at a time (`--takeover` to steal); multiple observers allowed.

## Waits

```
herdr wait output <pane_id> --match <text> [--source visible|recent|recent-unwrapped] [--lines N] [--timeout MS] [--regex] [--raw]
herdr wait agent-status <pane_id> --status idle|working|blocked|done|unknown [--timeout MS]
```

Timeout → exit code `1`. `wait output` matches unwrapped recent text (width-independent). Use `wait output` for commands/servers, `wait agent-status` for coding agents. `agent-status` supports `done`; `agent wait` (the agent-target form) supports `idle|working|blocked|unknown`.

## Integrations

Upgrade an agent's state from screen detection to authoritative hooks/plugins.

```
herdr integration install   <name>
herdr integration uninstall <name>
herdr integration status [--outdated-only]
```

Names: `pi omp claude codex copilot devin droid kimi opencode kilo hermes qodercli cursor mastracode`. Lifecycle-authoritative when installed: pi, omp, kimi, hermes, opencode, kilo, mastracode. Session-identity only (still screen-detected for state): claude, codex, copilot, devin, droid, qodercli, cursor.

## Plugins

Local executable workflow plugins (manifest `herdr-plugin.toml` + out-of-process commands).

```
herdr plugin install <owner>/<repo>[/subdir...] [--ref REF] [--yes]
herdr plugin list [--plugin ID] [--json]
herdr plugin uninstall <plugin_id|owner/repo[/subdir...]>
herdr plugin enable|disable <plugin_id>
herdr plugin link <path> [--disabled]          # local dev: dir with herdr-plugin.toml or a manifest path
herdr plugin unlink <plugin_id>
herdr plugin config-dir <plugin_id>
herdr plugin action list [--plugin ID]
herdr plugin action invoke <action_id> [--plugin ID]     # qualified id plugin.id.action when ambiguous
herdr plugin log list [--plugin ID] [--limit N]
herdr plugin pane open --plugin ID --entrypoint ID [--placement overlay|split|tab|zoomed] [--workspace ID] [--target-pane PANE] [--direction right|down] [--cwd PATH] [--env KEY=VALUE] [--focus|--no-focus]
herdr plugin pane focus|close <pane_id>
```

Manifests must declare `min_herdr_version`; install/link fail when the plugin needs a newer binary. `install` accepts GitHub shorthand only. See socket-api.md for the manifest shape and injected `HERDR_PLUGIN_*` env.

## Notifications

```
herdr notification show <title> [--body TEXT] [--position top-left|top-right|bottom-left|bottom-right] [--sound none|done|request]
```

Uses configured `[ui.toast]` delivery. `--position` only affects in-app Herdr toasts. `--sound done` = finished sound, `request` = needs-attention.

## Read sources

| Source | Meaning |
|--------|---------|
| `visible` | Current rendered screen. Best for UI feedback loops. |
| `recent` | Recent scrollback with terminal wrapping. |
| `recent-unwrapped` | Recent scrollback, soft wraps joined. Best for logs; matches what `wait output` sees. |
| `detection` | Bottom-buffer snapshot used by agent screen detection. |

## Environment variables

| Variable | Purpose |
|----------|---------|
| `HERDR_CONFIG_PATH` | Override config file path |
| `HERDR_SESSION` | Select a named session for CLI commands |
| `HERDR_SOCKET_PATH` | Low-level socket path override |
| `HERDR_ENV` | `1` inside Herdr-managed pane processes |
| `HERDR_PANE_ID` / `HERDR_TAB_ID` / `HERDR_WORKSPACE_ID` | Public ids for the running pane process |
| `HERDR_LOG` | Log filter, e.g. `HERDR_LOG=herdr=debug` |
| `HERDR_DISABLE_SOUND` | Disable sound even when sound notifications are on |

Herdr also injects `HERDR_SOCKET_PATH`, `HERDR_ENV=1`, `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID` into managed pane processes; Herdr-managed vars win over caller `--env` on conflict.

## JSON extraction cheat-sheet

Parse, never eyeball. `jq` if present, else `python3`:

| Command | id lives at |
|---------|-------------|
| `pane split` | `.result.pane.pane_id` |
| `pane get` / `pane current` | `.result.pane.pane_id` |
| `agent start` | `.result.agent.pane_id` |
| `agent get` | `.result.agent.pane_id` |
| `workspace create` | `.result.workspace.workspace_id` (also `.result.tab.tab_id`, `.result.root_pane.pane_id`) |
| `tab create` | `.result.tab.tab_id` (also `.result.root_pane.pane_id`) |
| `workspace list` | `.result.workspaces[].workspace_id` |
| `pane list` | `.result.panes[].pane_id` |
| `wait output` | `.result.matched_line`, `.result.read.text` |

```bash
id=$(herdr pane split --pane "$HERDR_PANE_ID" --direction down --no-focus \
     | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
```
