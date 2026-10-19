# Clouding Bar for Windows (beta)

Claude Code at a glance on Windows: a floating pill at the top of the
screen with the 5-hour limit, the context and when the limit resets; hover
it (2 s) or click it for the panel — both meters, the weekly limit, your
sessions. When Claude asks for a permission or asks a question, the card
comes up right there: **Allow**, **Always allow**, **Deny**, or pick an
answer. A tray icon holds the menu.

It speaks the same protocol as the macOS app ([docs/protocol.md](../docs/protocol.md)),
over a named pipe (`\\.\pipe\cloudingbar`) instead of a unix socket.

## Install

Download `Clouding Bar_<version>_x64-setup.exe` from the latest
[Windows build](../../actions/workflows/windows.yml) (or Releases), run it,
then click **Connect** in the panel (or **Connect to Claude Code** in the
tray menu). That copies the hook to `%USERPROFILE%\.cloudingbar` and adds it,
and the status line, to `%USERPROFILE%\.claude\settings.json` — merged, the
file backed up to `%USERPROFILE%\.cloudingbar\backups` first.

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

Buttons and templates typed into the chat, the message queue, dictation,
the model picker, the subagents list, file drop, the Touch Bar and the
notch (Mac only), Stats, and the 5-hour limit from the VS Code panel (it
comes from the status line in the terminal).
