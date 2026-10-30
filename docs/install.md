# Install in full

The [README](../README.md) has the short way in. Here are the details.

There's one Clouding Bar app for your Mac; you install it once, whichever way
you get it. What else each place needs:

| Where you work with Claude | What it needs |
|---|---|
| Claude Code — terminal, VS Code, Claude Desktop's Code tab | the app, then **Connect** in it. The plugin is optional |
| Cowork in Claude Desktop | the app, then **Sign In…** to claude.ai in its Settings (read the warning below first). The plugin isn't needed |
| Codex | the app, then **Connect** for Codex in it |

> **Cowork needs the claude.ai sign-in, and Anthropic's terms don't allow it.**
> Third-party apps may not collect or store claude.ai session keys, or reach
> claude.ai automatically; signing in goes against that and could put your
> account at risk, including suspension. Anthropic hasn't approved Clouding Bar.
> Use it at your own risk. Everything else works without it. Details:
> [privacy.md](privacy.md#the-claudeai-sign-in-optional).

- A plugin installed in **Claude Desktop** comes to Claude Code by itself, with
  your claude.ai account, a few minutes later.

## From Claude Code: the plugin

In Claude Code — the terminal, VS Code or Claude Desktop's Code tab:

```
/plugin marketplace add nikolanaidenko-eng/clouding-bar
/plugin install clouding-bar@clouding-bar
/reload-plugins
/clouding-bar:install
```

Type them inside Claude Code (after `claude` in a terminal), not in the
shell. `/reload-plugins` makes the chat you're in report to Clouding Bar
too. The plugin links Claude Code to the app (its hooks). `/clouding-bar:install`
gets the newest release from GitHub, checks it — signed with Clouding Bar's
Developer ID, notarized by Apple — and puts it in Applications. When the app
opens, say **Connect**: it adds its status line to `~/.claude/settings.json`
(the 5-hour limit and the context come that way, and a plugin can't bring a
status line), and in VS Code a small wrapper for the same limit. Then allow
Accessibility. Chats that were already open show up after `/reload-plugins`
in them, or start a new one. From then on a new Claude session opens
Clouding Bar if it's closed (Settings → General → Open with Claude).

## In Cowork (Claude Desktop)

1. Get the Mac app, if you haven't: the [.dmg](#download) below,
   `/clouding-bar:install` in Claude Code, or the plugin in Cowork (below).
   Open it, say **Connect**, allow Accessibility.
2. Only if you accept the risk above: open **Settings → General → Claude →
   claude.ai → Sign In…**, read the warning, press **I Understand** and sign
   in to claude.ai in the window that opens. It closes by itself.

Cowork tasks then show up in the chats list. No plugin and no connected
folder are needed. If you'd like Cowork to fetch the app for you, add the
plugin in Claude Desktop (**Customize** → **Plugins** → **Add** → **Add
marketplace** → `nikolanaidenko-eng/clouding-bar`) and ask a task "walk me
through Clouding Bar": it gives you the link to the newest .dmg and tells you
what to click. Had the plugin before 1.2.8? Update it there (or remove it): older ones
still ask Cowork to save its status to a folder, which nothing reads now.

## For Codex

1. Get the Mac app: the [.dmg](#download) below. Open it and allow
   Accessibility (the first question, about Claude Code, you can skip).
2. **Settings → General → Codex → Connect**: it adds its hooks to
   `~/.codex/hooks.json`, for permission requests on the bar.
3. Start Codex and choose *Trust all* (or `/hooks`): Codex runs hooks only
   after you trust them.

Codex chats show up even before step 2, read from Codex's own files.

## Download

[Download the latest .dmg](https://github.com/nikolanaidenko-eng/clouding-bar/releases/latest/download/Clouding-Bar.dmg)
(or `Clouding-Bar-<version>.dmg` from [Releases](https://github.com/nikolanaidenko-eng/clouding-bar/releases)), open it
and drag **Clouding Bar** into Applications. Releases are signed and
notarized by Apple. Opened straight from the disk image, it offers to move
itself to Applications (from the image it can't update itself), opens from
there and ejects the image.

Test builds (marked *beta*) aren't notarized yet, so on first launch macOS
says it can't check the app for malware. Click **Done**, then open
**System Settings → Privacy & Security**, scroll down to *"Clouding Bar"
was blocked* and click **Open Anyway** (on macOS 14 and earlier,
right-click the app → **Open** works too). Or, in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Clouding Bar.app"
```

On first launch it asks to **connect to Claude Code**: it adds a small hook
and a status line to `~/.claude/settings.json` (only the status line, with
the plugin in). Your settings are merged, never replaced, and backed up to
`~/.cloudingbar/backups` first. Then the tour opens.

## Updates

Once a day Clouding Bar asks GitHub whether a newer release is out and
offers it: the menu bar icon → **Install Update**, or Settings → General →
Updates. It's downloaded, checked like the first one (Clouding Bar's
Developer ID, notarized by Apple), put in place of the old copy and opened;
your settings and permissions stay. Turn the daily check off there. A build
of your own (`make install`) isn't touched.

The plugin updates through Claude Code: `/plugin marketplace update
clouding-bar`, or `/plugin` → Marketplaces → clouding-bar → Enable
auto-update.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/nikolanaidenko-eng/clouding-bar
cd clouding-bar
make install
```

This builds the app into `~/Applications`, puts the hook programs in
`~/.cloudingbar` and registers them with Claude Code (merged, backed up).

## Permissions macOS asks for

One is needed; the rest are asked the first time you use what needs them,
and only once — updates keep them.

| Permission | Why | |
|---|---|---|
| Accessibility | to type your buttons and chat lines into Claude's chat, and to read window titles | needed |
| Automation (Terminal, iTerm) | to tell which tab is in front, and bring a chat's tab forward | only for chats in a terminal |
| Microphone, Speech Recognition | dictation | only if you dictate |
| Screen Recording | the screenshot button | only if you use it |

Clouding Bar doesn't ask for your Documents or Desktop: the git branch of a
project there is read by the hook, inside Claude Code.

## VS Code

Claude's panel in VS Code doesn't run the status line, so the 5-hour limit
reaches Clouding Bar through a small wrapper instead. **Connect** sets it up
along with the rest, or later **Settings → General → VS Code: limit and
sending → Set Up** (it sets `claudeCode.claudeProcessWrapper`, keeping your
settings file as it is).
New chats report the limit from then on — and take the widget's messages
straight into Claude's input, beside the extension's own, so nothing is
typed and no window comes forward.
