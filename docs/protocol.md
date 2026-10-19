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
adds two fields:

| field | meaning |
|---|---|
| `claude_pid` | the Claude process (`CLAUDE_PID`, or found up the process tree). The app drops a session once this process is gone, even if `SessionEnd` never came. |
| `claude_entrypoint` | `CLAUDE_CODE_ENTRYPOINT`: `claude-vscode`, `cli`, … |

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

## Cowork status file

Cowork's hooks run away from this Mac. The `clouding-bar-cowork` plugin
(made in Settings → Cowork) works around that:
- its Stop hook works out the context fill;
- when it's time to report, it asks Claude to write one line to
  `.clouding-bar/cowork-status.json` in a folder connected to Cowork.

```json
{"v":1,"t":1792100000,"session":"…","project":"DiaRoute","context_tokens":104000,"context_window":200000,"model":"claude-opus-5-5"}
```

The app reads the file every 2 s. It shows the line as a session
`cowork-<session>`, which ends after 3 hours without news.

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
