---
name: guide
description: What Clouding Bar can do and how to set it up, in Cowork or in Claude Code. Use when the user asks about the Clouding Bar plugin — "I have the Clouding Bar plugin. Please walk me through what it can do.", how to install or set it up, or why Clouding Bar doesn't show a chat or a Cowork task.
---

# Walking someone through Clouding Bar

Answer in the user's language and keep it short: what it does in a few lines, then the setup
steps for where they are right now. Don't run commands or change files, except downloading the
installer in Cowork when the user wants it (below).

## What it is

Clouding Bar is a Mac menu bar app (macOS 12 or later). This plugin is only its link to Claude:
it reports what each chat is doing, and the app shows it — on the Touch Bar, in a floating pill
or in the notch — and lets you answer from there.

- Every chat with its own colour, its own Cloud and a short name: working, waiting for you, done.
- The 5-hour limit, the context window, the model, the subagents at work.
- Claude's permission requests and questions, answered from the bar or the pill without going
  back to the chat.
- A screenshot of an area of the screen, or a file dropped on the pill, goes straight into the
  chat; dictation too.
- A heads-up when another chat finishes; stats of how much you used.

## Where are you?

- **Cowork** — this chat runs in Cowork's Linux sandbox, with the task's folders under `mnt/`.
  Follow "In Cowork".
- **Claude Code on a Mac** — the terminal, VS Code or Claude Desktop's Code tab. Follow
  "In Claude Code".

## In Cowork

The plugin already does its part here. What's left happens on the Mac.

Where the folders are: in Cowork on the Mac, under `mnt/` here. In Cowork in the cloud
(`CLAUDE_CODE_ENTRYPOINT` is `remote_cowork`), not here at all — they stay on the user's
computer, under `~/mnt/` for the tool that runs commands there (`device_bash`); do anything with
them through that tool.

**Start with the folder — always, before anything else.** Check whether a folder from the
user's Mac is connected to this task. If none is, the first thing you say is: connect one
(any folder they work in, there's no special Clouding Bar folder; **+ → Add folder** in Claude
Desktop). Say why in a line: Clouding Bar sees a Cowork task only through a connected folder, and
the installer will go into it. Don't lead with downloading the app some other way, or with
Claude Code: the user came here to use Clouding Bar in Cowork, and without a folder Cowork
won't reach it anyway.

One Clouding Bar app serves Claude Code, Cowork and Codex. If it's already on this Mac (from
Claude Code or a .dmg), skip step 1. Claude Code and Codex need no plugin: **Connect** in the
app sets them up. Cowork needs this plugin in Claude Desktop; from there it also comes to
Claude Code a few minutes later, but a plugin installed in Claude Code doesn't reach Cowork.

Once a folder is connected:

1. **Put the installer in it** — don't wait to be asked; it can't be installed from Cowork
   itself (there's no macOS here, so `/clouding-bar:install` won't work in this chat):
   ```
   url=$(curl -fsSL https://api.github.com/repos/nikolanaidenko-eng/clouding-bar/releases/latest \
     | python3 -c "import json,sys; print([a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'].startswith('Clouding-Bar-') and a['name'].endswith('.dmg')][0])")
   curl -fL "$url" -o "<the connected folder>/${url##*/}"
   ```
   (In the cloud, run it with `device_bash`, into the folder under `~/mnt/` there.)
   Then tell them: open that `Clouding-Bar-….dmg` in Finder and drag Clouding Bar into
   Applications. Only if the download fails, give the link — the official one, always the newest
   release: <https://github.com/nikolanaidenko-eng/clouding-bar/releases/latest> (the
   `Clouding-Bar-….dmg` under Assets). Don't try to install it yourself by controlling the
   screen: opening the .dmg is quicker.
2. **Open Clouding Bar.** It asks to connect to Claude Code (say **Connect**) and for
   Accessibility, the one permission it needs. macOS asks once to let it read the folder.
3. Within a minute Clouding Bar marks the folder (`.clouding-bar/mode`) and switches its Cowork
   status on by itself; from the next reply this task shows up on the bar. How often it reports:
   Clouding Bar → Settings → Cowork (off, thresholds, every reply).
4. A question Cowork asks in Claude Desktop shows up on the Touch Bar and in the pill, and can be
   answered there (Claude Desktop's window has to be on the current desktop).

If a hook asks you to write a line to `.clouding-bar/cowork-….json` in a connected folder, that's
this plugin: Clouding Bar can't reach this task any other way. Do what it asks — that line, and
in the cloud the one word it asks you to leave in this sandbox — and nothing else; in the cloud
the line goes in with `device_bash`, into the folder under `~/mnt/` there.

## In Claude Code

1. `/reload-plugins`, so the chat that's open reports too, then `/clouding-bar:install` — it gets
   the newest release from GitHub, checks it (Clouding Bar's Developer ID, notarized by Apple)
   and puts it in Applications.
2. When the app opens: **Connect** (it adds its status line — the 5-hour limit and the context —
   to `~/.claude/settings.json`, and in VS Code a small wrapper), then allow Accessibility.
3. Chats that were already open show up after `/reload-plugins` in them, or in a new chat.

## Good to know

- No account, no analytics, no server of its own. The plugin itself uses no network, except
  `/clouding-bar:install` downloading the app from GitHub.
- The app checks GitHub for updates once a day (menu bar icon → Check for Updates).
- Everything else: <https://github.com/nikolanaidenko-eng/clouding-bar>.
