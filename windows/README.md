# Clouding Bar for Windows (in development)

**Not ready yet, and there's nothing to download: Clouding Bar is for Mac only
for now.** This folder is the work in progress, and the earlier test builds have
been taken down. The app for Mac: [the main README](../README.md).

What it does so far: a floating pill at the top of the screen with the 5-hour
limit, the context and when the limit resets; hover it (2 s) or click it for the
panel — both meters, the weekly limit, and your chats as tabs. When Claude asks
for a permission or asks a question, the card comes up right there: **Allow**,
**Always allow**, **Deny**, or pick an answer. A tray icon holds the menu.

Chats are told apart as on the Mac: each by its title (VS Code's chat tab
shows the same) and its own colour. The widget follows the chat whose title
the window in front shows, else the one you picked or followed last; a click
on a tab follows that chat and opens it in VS Code. Requests say which chat
they come from. When the chat shown finishes while another is still at work,
it shows a tick ("Done · your turn") and a moment later the chat at work.

It speaks the same protocol as the macOS app ([docs/protocol.md](../docs/protocol.md)),
over a named pipe (`\\.\pipe\cloudingbar`) instead of a unix socket.

## What's here

| | |
|---|---|
| `core/` | the protocol, sessions and limits, Claude's requests and their answers, the settings merge — tested on any OS |
| `hook/` | `cloudingbar-hook.exe`: the hook command (and `--statusline`) |
| `app/` | the Tauri app: `src-tauri/` (Rust) and `ui/` (the pill and the panel, plain HTML) |

```sh
cargo test --workspace          # anywhere
cd app && npm ci && npx tauri build   # on Windows: the installer
```

Built on a Mac, the app runs too (for development): it then keeps to
`~/.cloudingbar-dev` and never touches Claude Code's real settings.

## Not yet (the macOS app has these)

Writing to a chat from the widget, buttons and templates, the message queue,
dictation, screenshots and file drop, the model picker, the subagents list,
Stats, Cowork, claude.ai chats, Codex, updates from inside the app, and the
5-hour limit from the VS Code panel (it comes from the status line in the
terminal). The Touch Bar and the notch are Mac only.
