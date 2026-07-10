# Herdr socket API

Use the CLI wrappers ([`cli-reference.md`](cli-reference.md)) for most automation. Use the raw socket API only when you need direct request/response control or **long-lived event subscriptions**. Upstream: <https://herdr.dev/docs/socket-api/>.

## Contents
- [Transport](#transport)
- [Method index](#method-index)
- [session.snapshot bootstrap](#sessionsnapshot-bootstrap)
- [Pane control details](#pane-control-details)
- [Layout export/apply](#layout-exportapply)
- [Agent state reporting](#agent-state-reporting)
- [Display-only metadata](#display-only-metadata)
- [Event subscriptions](#event-subscriptions)
- [Notifications & window title](#notifications--window-title)
- [Worktrees](#worktree-methods)
- [Plugin host surface](#plugin-host-surface)
- [Response & error shapes](#response--error-shapes)

## Transport

Newline-delimited JSON over a local socket (Unix domain socket; Windows named pipe). One request per line:

```json
{"id":"req_1","method":"ping","params":{}}
```

Success echoes the `id`: `{"id":"req_1","result":{"type":"pong"}}`. Event subscriptions keep the connection open after the initial ack. Socket path resolution: `--session` → `HERDR_SOCKET_PATH` → `HERDR_SESSION` → default (`~/.config/herdr/herdr.sock`). Check compatibility with `ping` / `herdr status` (protocol version) before depending on new behavior; handle unknown fields gracefully.

`herdr api schema [--json] [--output PATH]` prints the socket schema bundled with the installed binary (raw requests, success/error responses, emitted events, subscription events).

## Method index

| Area | Methods |
|------|---------|
| Server | `ping`, `server.stop`, `server.reload_config`, `server.agent_manifests`, `server.reload_agent_manifests` |
| Notification | `notification.show` |
| Client | `client.window_title.set`, `client.window_title.clear` |
| Session | `session.snapshot` |
| Workspace | `workspace.create/list/get/focus/rename/move/close` |
| Worktree | `worktree.list/create/open/remove` |
| Tab | `tab.create/list/get/focus/rename/move/close` |
| Pane | `pane.split/swap/move/zoom/layout/process_info/neighbor/edges/focus_direction/resize/list/current/get/rename/send_text/send_keys/send_input/read/report_agent/report_agent_session/report_metadata/clear_agent_authority/release_agent/close/wait_for_output` |
| Layout | `layout.export/apply/set_split_ratio` |
| Agent | `agent.list/get/read/explain/send/rename/focus/start` |
| Events | `events.subscribe`, `events.wait` |
| Integration | `integration.install/uninstall` |
| Plugin | `plugin.link/list/unlink/enable/disable/action.list/action.invoke/log.list/pane.open/pane.focus/pane.close` |

Public pane ids like `w1:p1`. Methods whose schema makes `pane_id` optional use the active focused pane when omitted (`pane.move` always needs the source `pane_id`). `pane.send_keys` / `pane.send_input.keys` take Herdr key-combo strings (see cli-reference key syntax), not `prefix+` strings.

## session.snapshot bootstrap

One-time bootstrap for clients that keep a local cache: version/protocol metadata, focused workspace/tab/pane ids, workspace/tab/pane records, tab layout snapshots, agent records, and worktree provenance on workspace records. **Not a subscription** — after reading it, `events.subscribe` and update the cache from events; call `session.snapshot` again after reconnect or when the cache may be stale. CLI: `herdr api snapshot`.

## Pane control details

Process-launching methods accept an `env` object applied to the new process only. Herdr injects `HERDR_SOCKET_PATH`, `HERDR_ENV=1`, `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID`; Herdr-managed vars win on conflict.

```json
{"id":"r","method":"pane.split","params":{"direction":"right","ratio":0.333,"env":{"HERDR_ROLE":"tests"}}}
{"id":"r","method":"pane.current","params":{"caller_pane_id":"w1:p1"}}
{"id":"r","method":"pane.neighbor","params":{"pane_id":"w1:p1","direction":"right"}}
{"id":"r","method":"pane.resize","params":{"pane_id":"w1:p1","direction":"right","amount":0.1}}
{"id":"r","method":"pane.zoom","params":{"pane_id":"w1:p1","mode":"toggle"}}
```

- `pane.current`: returns one `PaneInfo`; with `caller_pane_id`, that pane; else the active focused pane.
- `PaneInfo` includes `scroll` when available: `{offset_from_bottom, max_offset_from_bottom, viewport_rows}`; `offset_from_bottom == 0` ⇒ at bottom. Also `foreground_cwd` when resolvable (distinct from `cwd`, the pane/workspace cwd), and `agent_session` when an official integration reported a native session ref.
- `pane.swap` (same-tab only) preserves split shape/ratios/ids/processes. `reason ∈ {no_neighbor, same_pane, not_found, cross_tab}`. Directional or explicit `{source_pane_id, target_pane_id}`.
- `pane.move` to `{type: tab|new_tab|new_workspace}`. Existing-tab moves need `split: right|down`. Cross-workspace move keeps the terminal alive but assigns a new public pane id; subscribers get `pane.moved` (no fake close/create). `reason ∈ {same_tab, zoomed_tab}`.
- `pane.zoom` `mode ∈ {toggle,on,off}`; `reason ∈ {single_pane, already_zoomed, already_unzoomed}`.

## Layout export/apply

```json
{"id":"r","method":"layout.export","params":{"tab_id":"w1:t1"}}
```

Returns `{workspace_id, tab_id, zoomed, focused_pane_id, root}`. `root` is a BSP tree of `pane` nodes (`pane_id`, `label`, `cwd`, argv `command`) and `split` nodes (`direction: right|down`, `ratio`, `first`, `second`). Omit `tab_id`/`pane_id` to export the active tab.

`layout.apply` builds a fresh tab from a declarative tree (restores structure/labels/cwd/env/argv; does **not** preserve live PTYs, scrollback, or running processes). With `tab_id`, the replacement tab is created first, then the old tab closes.

```json
{"id":"r","method":"layout.apply","params":{"workspace_id":"wabc","tab_label":"dev","focus":true,
 "root":{"type":"split","direction":"right","ratio":0.65,
  "first":{"type":"pane","label":"editor","cwd":"/repo"},
  "second":{"type":"pane","label":"tests","cwd":"/repo","command":["sh","-c","just test"],"env":{"HERDR_ROLE":"tests"}}}}}
```

`layout.set_split_ratio`: `{tab_id, path:[], ratio}` → `layout_split_ratio_set`.

## Agent state reporting

Integrations report semantic state (affects waits, notifications, rollups):

```json
{"id":"r","method":"pane.report_agent","params":{"pane_id":"w1:p1","source":"custom:docs","agent":"docs-bot","state":"working","message":"building docs","custom_status":"indexing"}}
```

`state` is semantic; `custom_status` is a short display-only activity label. Session-only integrations report native session identity separately (does not affect waits/rollups):

```json
{"id":"r","method":"pane.report_agent_session","params":{"pane_id":"w1:p1","source":"herdr:codex","agent":"codex","agent_session_id":"..."}}
```

`pane.get/list`, `agent.get/list` expose read-only `agent_session {source,agent,kind,value}` when stored, else omitted.

## Display-only metadata

`pane.report_metadata` customizes presentation without taking over lifecycle state:

```json
{"id":"r","method":"pane.report_metadata","params":{"pane_id":"w1:p1","source":"user:claude-title","agent":"claude",
 "title":"Refactor auth middleware","display_agent":"Claude: auth","custom_status":"refactor auth",
 "state_labels":{"working":"refactoring auth","idle":"ready","done":"review ready"},"ttl_ms":3600000}}
```

Display-only: `working/blocked/idle`, waits, notifications, rollups still come from semantic state. `agent` guards the authoritative label; `applies_to_source` guards the active lifecycle authority source. `state_labels` keys ∈ `{idle,working,blocked,done,unknown}`. Clear one override with `clear_custom_status: true` (etc.) and the same `source`. Text is normalized: `custom_status` ≤32 chars, `title`/`display_agent`/each label ≤80 chars, control chars stripped, empty ignored. `source`/`applies_to_source` ≤80 chars, `[A-Za-z0-9:._-]`. `ttl_ms` 1–86400000. `seq`: same-`source` reports ≤ last accepted seq are ignored by pane state.

## Event subscriptions

```json
{"id":"sub_1","method":"events.subscribe","params":{"subscriptions":[
  {"type":"pane.agent_status_changed","pane_id":"w1:p1","agent_status":"blocked"}]}}
```

First response acks; later lines are pushed events. Event families:

- **workspace**: `created` (optional `worktree` provenance), `updated`, `renamed`, `moved` (`workspace_id`, `insert_index`, ordered `workspaces`), `closed` (final snapshot when identifiable), `focused`.
- **tab**: `created`, `closed`, `focused`, `renamed`, `moved` (`tab_id`, `workspace_id`, `insert_index`, ordered `tabs`).
- **pane**: `created`, `closed`, `focused`, `moved`, `exited`, `agent_detected`, `output_matched`, `agent_status_changed`, `scroll_changed` (per `pane_id`).
- **layout**: `updated` (carries the tab's `PaneLayoutSnapshot`).
- **worktree**: `created` (opened `workspace` + `worktree`), `opened` (`already_open`), `removed` (`workspace_id`, `worktree`, `forced`).

Use `events.subscribe` for streams; dedicated `wait` helpers (`wait output`, `wait agent-status`) for one-shot waits.

## Notifications & window title

```json
{"id":"r","method":"notification.show","params":{"title":"build failed","body":"api workspace","position":"top-left","sound":"request"}}
```

`title` required (must have visible text after sanitization; ≤80 chars). `body` ≤240 chars. `position` applies only with `ui.toast.delivery="herdr"`. `sound ∈ {none,done,request}`. Response `reason ∈ {shown, disabled, rate_limited, no_foreground_client, busy}`.

`client.window_title.set {title}` / `client.window_title.clear {}` set/restore the outer terminal window title of the foreground client.

## Worktree methods

`worktree.create {workspace_id|cwd, branch, base?, path?, focus?}` → new `workspace`, `tab`, `root_pane`, `worktree`. `worktree.open {workspace_id|cwd, path|branch, focus?}`. `worktree.remove {workspace_id, force?}` runs `git worktree remove`, never deletes the branch. Raw-socket `cwd`/`path` must be absolute (CLI expands relative). Emits `workspace.created/tab.created/pane.created/worktree.created` (create), `worktree.opened` (+ creation events for a new workspace), `worktree.removed` (+ `workspace.closed` if still open).

## Plugin host surface

Plugin = a `herdr-plugin.toml` manifest + out-of-process commands. Installed/linked plugins persist in `plugins.json` beside `session.json`.

```toml
id = "example.worktree-bootstrap"
name = "Worktree Bootstrap"
version = "0.1.0"
min_herdr_version = "0.7.0"   # required; link refused if newer than running binary
description = "Prepare new worktrees"
platforms = ["linux","macos","windows"]

[[build]]
command = ["bun","install"]

[[actions]]
id = "bootstrap"
title = "Bootstrap worktree"
contexts = ["workspace"]
command = ["bun","run","bootstrap.ts"]

[[events]]
on = "worktree.created"
command = ["bun","run","bootstrap.ts"]

[[panes]]
id = "board"
title = "Worktree board"
placement = "overlay"
command = ["bun","run","board.ts"]

[[link_handlers]]
id = "github-issue"
title = "Open GitHub issue"
pattern = "^https://github\\.com/[^/]+/[^/]+/(issues|pull)/[0-9]+$"
action = "bootstrap"
```

Actions/panes are manifest-only in v1 (no runtime registration). Event-hook `on` names are validated at link time (unknown names warn, don't fail — check `warnings`). `plugin.action.invoke {action_id, context?}` fills missing context from the active workspace/tab/focused pane/worktree/request id. Injected env for plugin commands: `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_ENV=1`, `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_CONFIG_DIR`, `HERDR_PLUGIN_STATE_DIR`, `HERDR_PLUGIN_CONTEXT_JSON`, available `HERDR_WORKSPACE_ID/TAB_ID/PANE_ID`, plus `HERDR_PLUGIN_ACTION_ID` (actions), `HERDR_PLUGIN_EVENT`/`HERDR_PLUGIN_EVENT_JSON` (events), `HERDR_PLUGIN_ENTRYPOINT_ID` (panes). No Herdr-managed plugin storage in v1 — config/state dirs are path discovery only.

## Response & error shapes

```json
{"id":"req_1","result":{"type":"pane_info","pane":{"pane_id":"w1:p1","terminal_id":"term_abc","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"working","revision":42}}}
{"id":"req_1","error":{"code":"not_found","message":"pane not found"}}
```

`server.agent_manifests` → `agent_manifest_status` with per-agent `source`, `source_kind`, `active_version`, `cached_remote_version`, `local_override_shadowing_remote`, `remote_update_result` (omitted fields when unavailable). `server.reload_agent_manifests` → `agent_manifest_reload`. `agent.explain` → the same explain object as `herdr agent explain --json` (final state, manifest source/version, matched rule, evidence, skip/idle-fallback reasons, `screen_detection_skip_reason` under a full lifecycle authority).
