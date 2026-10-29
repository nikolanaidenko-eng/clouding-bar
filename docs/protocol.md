# Clouding Bar protocol

How Claude Code talks to the app. Nothing here depends on macOS except the
transport, so a Windows version can speak the same JSON over a named pipe or
a localhost port.

## Transport

- macOS: a unix socket at `~/.cloudingbar/cloudingbar.sock`, created by the app.
- One connection carries **one message**: a JSON object on a single line,
  ended by `\n` or by the sender closing the connection.
- Senders:
  - `cloudingbar-hook`, the command for every Claude Code hook event;
  - `cloudingbar-statusline.sh`, the status line, for terminal sessions;
  - `cloudingbar-tap`, which reads Claude's stdout behind the VS Code panel
    (`claudeCode.claudeProcessWrapper`);
  - `cloudingbar-relay.sh`, the old hook command. Sessions started before an
    upgrade keep calling it.

## Messages to the app

### Hook events

This is the JSON Claude Code gives the hook, unchanged
([hooks reference](https://code.claude.com/docs/en/hooks)). `cloudingbar-hook`
adds a few fields:

| field | meaning |
|---|---|
| `claude_pid` | the Claude process (`CLAUDE_PID`, or found up the process tree). The app drops a session once this process is gone, even if `SessionEnd` never came. |
| `claude_entrypoint` | `CLAUDE_CODE_ENTRYPOINT`: `claude-vscode`, `cli`, … |
| `claude_effort` | `CLAUDE_EFFORT`, the turn's reasoning effort. |
| `git_branch` | the branch of `cwd`, read from `.git/HEAD`. |
| `file_branch` | the branch of the folder of `tool_input.file_path` (or `notebook_path`). |

The branches are read in the hook because it runs inside Claude Code, which
already may read the project. In Documents, Desktop, Downloads, iCloud Drive
or on another disk the app would have to ask macOS first, so there it takes
the hook's word; elsewhere it reads `.git/HEAD` itself, to notice a checkout
between events.

Registered events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`,
`Notification`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`,
`PermissionRequest`, `SubagentStart`, `SubagentStop`.

What each event does to the character:

| event | state |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse(Failure)` | work |
| `Stop`, `SessionStart`, `[Request interrupted by user]` in the transcript | sleep |
| a request on the bar; `Notification` of type `permission_prompt` / `elicitation_dialog` / `agent_needs_input` | wait |
| `SessionEnd` | session removed |

Subagents (the panel's list, the bar's "agents" button), `Session.trackAgents`:

| event | what happens |
|---|---|
| `PreToolUse` of `Agent` (no `agent_id`) | a subagent starts: `subagent_type`, `description`, `run_in_background` |
| `PostToolUse(Failure)` of `Agent`, same `tool_use_id` | it's done, unless it runs in the background |
| `SubagentStart`, or any hook with `agent_id` | gives it its id; a `PreToolUse` there is what it's doing now |
| `SubagentStop` | that `agent_id` is done |
| `Stop` | foreground subagents are done |

### Short chat names (a hook answer)

On `UserPromptSubmit` (never Codex's), if the app has made up a short name for
the chat (`~/.cloudingbar/names/<session_id>.json`, `{"name":…,"claude":true}`),
the hook prints, whether or not the app runs:

```json
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"Login test"}}
```

Claude Code then writes `{"type":"custom-title","customTitle":"Login test"}` to
the transcript. Nothing is printed when the transcript already has any
`custom-title` (ours, done — or one the person gave, which is never
overwritten), after three offers, or with `"shortNames": false` in the config.

## Which chat is shown

Each session is a chat. Its name is its title from the transcript — a
`{"type":"custom-title","customTitle":…}` line (a name you gave it) wins over
`{"type":"ai-title","aiTitle":…}` (Claude Code's own) — else its project's
folder. A short name made up for it (1–3 words, `ShortNamer`) is shown instead
of a long title, unless there is a `custom-title` that isn't ours. The tab may
still carry the old title for a moment, so a window is matched by every title
the chat has had. It gets one of ten colours, the first no live chat has.

The chat the widget and the bar follow (`SessionStore.focus`):

1. Terminal or iTerm in front: the chat whose Claude process runs on the
   tty of the tab in front (asked by AppleScript).
2. The window title names a chat's title (VS Code's chat tab: "Status bar —
   GitHub"; a terminal's title, its spinner stripped).
3. Of the chats of the project the window shows, the one picked in the
   widget, or followed last, else the latest active.
4. No chat's window in front: the one picked or followed last.

Picking a chat in the widget, the menu or the Touch Bar brings it up: its
Terminal or iTerm tab; or its VS Code window (by title, or any folder of its
path) and then `vscode://anthropic.claude-code/open?session=<id>`. A window
that can't be seen is asked for with `vscode://file/<folder>`, which brings
up the window that has it — VS Code is never forced to open a new one.
Typing into a chat (the queue, Insert, auto-compact) waits until that chat is
surely in front: by title or tty, or the only chat of its project.

Transcripts repeat themselves: a reply is several lines with one
`message.id`, and Claude Code writes some replies and edits again later. Each
reply's usage and each edit (`uuid`) count once; an old reply written again
doesn't move the context.

## Model and effort

The widget and the bar type `/model <alias>` or `/effort <level>` into the chat
in front. Claude Code notes the switch in the transcript as
`<local-command-stdout>Set model to `Opus 5.5 (1M context)`…` (older: the id)
and `Set effort level to high: …`; the app reads those lines, so the new
model shows at once. Hooks carry the turn's effort as `CLAUDE_EFFORT`.

### Status

These are messages without `hook_event_name`, in the status line's shape:
`session_id`, `rate_limits.five_hour.{used_percentage, resets_at}`,
`context_window.{used_percentage, context_window_size}`, `model.id`.
- They update a session the app already knows. They never create one.
- The 5-hour limit belongs to the account, so the newest value wins.

## Codex

OpenAI's Codex runs the same hook, from `~/.codex/hooks.json`, as
`cloudingbar-hook --codex`; the hook marks its events `"claude_entrypoint":
"codex"`. Codex has `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`,
`Interrupt` (you stopped a turn: no `Stop` follows), `PreToolUse`,
`PostToolUse`, `PermissionRequest`, `SubagentStart` and `SubagentStop` (no
`Notification`), and runs hooks only after you trust them (`/hooks`, or
"Trust all" at start). The trust is per entry: Connect only ever appends.
`model` in its hooks is a plain string.

- Permissions: the same outputs, except **Always** is a plain allow (Codex
  refuses `updatedPermissions`), so the bar doesn't offer it. Codex holds its
  own prompt while the hook waits, so its requests are held briefly, like the
  terminal's. A `PermissionRequest` marks the chat as asking (`waitingNotice`)
  until `PostToolUse`, `Stop`, `Interrupt` or a new prompt. `apply_patch`
  shows its files, from the `*** Update/Add/Delete File:` lines.
- Its questions (`request_user_input`) can't be answered from a hook.
- **Its files**, read with or without hooks: `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`
  (`.zst` ones are old and skipped), lines of `{"timestamp", "type", "payload"}`.
  A file is read from its last 3 MB, whole lines only. Used:
  - `session_meta` (first line): `id`, `cwd`, `originator` ("codex_cli_rs" =
    Terminal, "codex_vscode" = VS Code, "Codex …" = App), `source` (a chat of a
    person is `cli`/`vscode`/custom; `subagent`, `exec`, `mcp` are not shown), `git.branch`;
  - `turn_context`: `model`, `effort`;
  - `event_msg` `task_started` (working), `task_complete` / `turn_aborted` (done);
  - `event_msg` `token_count`: `info.last_token_usage.total_tokens` over
    `info.model_context_window` for the context — as Codex shows it, the first
    12 000 tokens not counted — `info.total_token_usage` for tokens, and
    `rate_limits` for **Codex's own** limits: `primary` / `secondary` with
    `used_percent`, `window_minutes` (300 = 5-hour, 10080 = weekly; one window
    is possible, other lengths are ignored), `resets_at` (unix seconds, an ISO
    string in older files; `resets_in_seconds` in the oldest), and `plan_type`.
    Only `limit_id` empty or `codex` is the account's; other buckets are kept aside.
  The newest report wins, whichever chat's file it came from; a window whose
  `resets_at` has passed reads as reset (0 %).
- Without hooks, a chat whose file changed in the last quarter of an hour (an
  hour while a turn is on) is shown, marked ambient: no process to watch, no
  permissions to answer. A hook that arrives takes it over; a `SessionEnd`
  keeps it from coming back.
- While a Codex chat is in front, the widget and the bar show Codex's limits.

### Codex's own server

Codex 0.164 runs one app-server per user (`codex app-server daemon`, marked
experimental), which every `codex` in a terminal is a client of; it holds
their chats' files. Settings → General → Codex → *Live limits and sending*
(`codexServer`, on) uses it, and only it (`Core/CodexServer.swift`):

- **Only when it runs.** Its socket is `~/.codex/app-server-control/app-server-control.sock`
  (a link into `/tmp/codex-daemon-<uid>/`); its pid is in
  `~/.codex/app-server-daemon/daemon.pid`. Both there and the process alive:
  `codex app-server proxy --sock <that socket>` is run — the copy in
  `~/.codex/packages/app-server-daemon/current/bin`, else Homebrew's,
  `/usr/local/bin`, `~/.local/bin`. The proxy only relays bytes to the
  socket and starts nothing. No server, or a Codex without `proxy`: nothing
  is run, and everything works from the files as before. Lost: tried again
  after 5 s, doubling to 5 minutes.
- **Framing.** A WebSocket over the proxy's stdin and stdout (an HTTP upgrade
  to `/` — `/daemon/shutdown` on the same socket stops the server — then
  masked text frames), one JSON-RPC message per frame, without `"jsonrpc"`.
- **What we send.** `initialize` (`clientInfo.name` `clouding-bar`), then
  `initialized`; `account/rateLimits/read` (`excludeResetCreditDetails`) on
  connect and every 5 minutes — Codex asks its backend each time;
  `thread/loaded/list` every 10 s and right before sending; `turn/start`
  `{threadId, input: [{type: "text", text}]}`. Nothing else: no
  `thread/resume`, `thread/start`, fork or `turn/steer`.
- **Limits.** The `codex` bucket of `rateLimitsByLimitId` (else `rateLimits`),
  read by the files' rules (windows by length, newest wins, a passed reset
  reads as reset), reported now. `account/rateLimits/updated` is taken too,
  but 0.164 sends it only to a chat's own clients, and we join no chat: the
  files still bring each reply's numbers.
- **Sending.** `turn/start` finds only a chat the server has loaded — one it
  hasn't is "thread not found", never read from disk — so no second writer of
  a chat's file and no copy of it. While a turn runs it joins that turn
  (codex-rs `start_or_steer_turn`), so the queue holds the words until the
  chat's file or hooks say the turn ended; *Send now* sends at once. Errors
  keep the words in the queue; no answer in 15 s may mean they went in, so
  they aren't sent again. The chat's id goes as the server spells it; dropped
  files go as quoted paths in the words.
- **Approvals.** Codex sends them to the clients that joined the chat
  (`thread/resume`), never to whoever started the turn — so a turn we start
  asks in its own window, and with hooks on the bar as before. Anything the
  server asks us anyway (approvals, `requestUserInput`, elicitations, tool
  calls, `account/chatgptAuthTokens/refresh`, attestation) gets a JSON-RPC
  error: an approval reads that as declined. No credentials are read or
  given; if `account/updated` says another app supplies Codex's sign-in
  (`chatgptAuthTokens`, whose refreshes go to every client), we disconnect.
- A chat whose tab closed stays loaded in the server for up to 30 minutes
  (`thread_unload_delay`): words sent then run with no tab to see them; the
  chat shows them when resumed.

## Requests: answers from the bar

Two hook events wait for an answer:
- `PermissionRequest`, for any tool;
- `PreToolUse` with `tool_name: "AskUserQuestion"`.

For these, `cloudingbar-hook` keeps the connection open after sending. The app
replies with JSON lines:

| reply | meaning |
|---|---|
| `{"hold": N}` | Keep waiting up to N more seconds. It must arrive within 2 s of the request, and the app sends it again whenever you interact. |
| `{"output": {…}}` | Final. The hook prints this object as its output for Claude. |
| `{"pass": true}` | Final. No decision, so Claude's own UI handles it. |

### The rule: Claude never waits on a broken app

`cloudingbar-hook` exits 0 with no output, which means "no decision", when:
- the socket is missing or refuses the connection (app not running);
- no `hold` arrives within 2 s (app hung);
- the connection closes (app quit or crashed);
- a hold runs out, or a line isn't valid JSON;
- the hard caps pass: 300 s for a question, 900 s for a permission. `alarm()`
  backs these up.

Checked on 15.10.2026 with Claude Code 2.1.296: app killed, frozen
(SIGSTOP) and not running. The hook returned in 0.03–2.1 s every time, and
Claude's own UI got the request.

### Which requests the bar holds

- **VS Code and the desktop app** (`claude-vscode`, `claude-desktop`):
  - Claude sends `PermissionRequest` to the hook and to its own dialog at
    the same time. The first answer wins, and Claude closes the other side.
  - So the bar keeps these up to `permissionHoldSeconds` (600). They cost
    nothing: the panel never waits.
  - Questions are taken from their `PermissionRequest` as well. Their
    `PreToolUse` passes at once.
- **Everywhere else** (terminal, scripts): Claude may wait on the hook.
  - The bar takes questions from `PreToolUse` and permissions as usual.
  - It holds them only while the Touch Bar or the floating widget is
    showing, for `questionHoldSeconds` (15, renewed while you interact).
  - Otherwise it passes at once.
- When both the bar and the widget are hidden, it passes everything that
  can block. The same
  happens on esc, when the hold runs out, and when Claude moves on (`Stop`,
  `UserPromptSubmit`, `SessionEnd`, or `PostToolUse` of the same tool).

### Outputs (checked against Claude Code 2.1.296)

Allow, permission:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

Always, permission: echoes Claude's `permission_suggestions`.

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[…]}}}
```

Deny, permission:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the Touch Bar."}}}
```

Question answered via `PermissionRequest`. For multiple choice, labels are
joined with `", "`; "Other…" gives the typed text.

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"questions":[…],"answers":{"Which color?":"Blue"}}}}}
```

Question answered via `PreToolUse`:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":[…],"answers":{…}}}}
```

## Cowork and chats through claude.ai

Cowork tasks and claude.ai / Claude Desktop chats are read from claude.ai,
once the user signs in (Settings → General → Claude → claude.ai →
**Sign In…**). The app takes the `sessionKey` cookie from claude.ai's own
sign-in page, keeps it only in the macOS Keychain, and sends it as a cookie.
Only to claude.ai, redirects never followed. GET requests, and a POST only
for what the user sends: a message to a Cowork task or to a Claude Code chat
(Claude Desktop or Terminal) with Remote Control on, or an answer to what a
Cowork task asks.
The addresses are unofficial and can stop working at any time.

| request | when | used for |
|---|---|---|
| `/api/organizations` | once | the organization id |
| `/api/organizations/{org}/usage` | every minute | the 5-hour and weekly limit |
| `/api/organizations/{org}/chat_conversations_v2` | every 20 s while a chat runs or waits, else every minute | the chats list |
| `/v1/code/sessions/{id}/events` | for a Cowork task that is running or just finished | context and model |
| `/v1/code/sessions/{id}` | a Cowork task waiting for you, each time the list is read; a Claude Code chat's Remote Control every 30 s | `worker_status` `"requires_action"` with `external_metadata.pending_action` (`tool_name`, `input`, `request_id` — a question's in `suppressed_request_id`; `dialog:*` left alone): what it asks; `environment_kind` `"bridge"` and `connection_status`: Remote Control on the line |
| POST `/v1/code/sessions/{id}/events` | only when the user sends | `{"events":[{"payload":{"type":"user","uuid","session_id","parent_tool_use_id":null,"message":{"role":"user","content":[…]}}}]}` — a message, as Claude Code sends one; `{"events":[{"payload":{"type":"control_response","uuid","response":{"subtype":"success","request_id","response":<decision>}}}]}` — an answer, the decision as a `PermissionRequest` hook gives it |

A Remote Control session id `session_X` is `cse_X` in these addresses. A
Claude Desktop Code chat is matched by Claude Code's session id to the app's
own file (`~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json`:
`cliSessionId`, `sessionId` = `local_…`, `bridgeSessionIds`); its link is
`claude://code/continue?session=local_…`. A Terminal chat's Remote Control
is in Claude Code's own record of it, `~/.claude/sessions/<pid>.json`
(`sessionId`, `bridgeSessionId`). Only with the claude.ai key given for the
chats too (not "Only the Limit").

Fields used from a conversation: `uuid`, `name`, `model`, `updated_at`,
`live_status` (`"running"` or null), `live_status_started_at`, `needs_input`,
`needs_input_kind` (`"permission"` or `"question"`), `last_settled_at`,
`workspace_session_id` (set for a Cowork task: the `{id}` of the events
request).

Events come newest first. From `assistant` events the app reads
`payload.message.model` and `payload.message.usage` (a subagent's, with a
`parent_tool_use_id`, aside); the context is
`input_tokens + cache_read_input_tokens + cache_creation_input_tokens`. The
answer holds the task's messages too; they are dropped once it's read, never
kept or logged.

Each chat becomes a session `cowork-<uuid>` (a Cowork task) or
`claudeai-<uuid>`: `name` → its title, `uuid` → its Desktop page
(`/chat/<uuid>`), kept in `sessions.json` with its state, model and context.
Sign Out forgets them. A 429 quiets every request for a minute, doubling up
to 15.

A chat opens in Claude Desktop by its id: `claude://claude.ai/chat/<uuid>`.
Shown: chats at work, waiting for you, or active in the last half hour (3 hours
till 28.10). One archived (`is_archived`) or no longer in the list is dropped at once.

Older versions wrote `.clouding-bar/cowork-<session>.json` into folders
connected to a Cowork task. Nothing writes or reads them now; they are safe
to delete.

Claude Desktop's window title doesn't say which chat it shows, so with the
app in front the widget follows its chats (Cowork, Code): the one you
picked, else the latest.

## Files in `~/.cloudingbar`

| file | what |
|---|---|
| `config.json` | settings, every key optional (`Sources/CloudingBar/Core/Config.swift`) |
| `sessions.json` | known sessions, so a restart keeps them |
| `last-status.json` | last 5-hour limit |
| `debug.log` | one line per tap (`trusted=`, front app) and what happened to each request |
| `backups/` | `settings.json` as it was before each install changed it |
| `queue.json` | the task queue |
| `limit-history.jsonl` | the 5-hour limit over time, for Stats |
| `stats-cache.json` | per-transcript hour totals, for Stats |
| `shots/` | screenshots taken from the widget, and pictures dropped on it without a file (`drop-*.png`) |
