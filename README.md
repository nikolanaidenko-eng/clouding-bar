# Clouding Bar

**Claude Code at a glance — on your Touch Bar, in a floating pill, or in the notch.**

<p align="center">
  <img src="docs/demo.gif" width="640" alt="The notch growing for a question and answering it, the pill pulled wider, the Touch Bar">
</p>

Clouding Bar is a small macOS menu bar app for people who work with
[Claude Code](https://code.claude.com). It shows what Claude is doing —
your 5-hour limit, the context window, the model, the subagents at work —
and lets you answer Claude's questions and permission requests without
going back to the chat. Cloud, the little character, dozes while Claude is
idle, hops while it works and waves when it needs you.

It works in the terminal, in the VS Code extension and with the desktop
app, on any Mac with macOS 12 or later. A Touch Bar is a bonus, not a must.
A first version for **Windows** is in [windows/](windows/README.md).

## What it does

**See where you are**
- **The pill** floats over your windows: the 5-hour limit, the context,
  when the limit resets, the model, lines changed, the git branch,
  subagents. Pull its outline to resize it — wider shows more, taller
  stands it up as a column — and drag items onto each other to reorder.
- **The notch.** Drag the pill to the top of the screen and it docks in the
  notch, the numbers on either side of the camera. Macs without a notch get
  a drawn one. When Claude asks something, the notch grows so you can
  answer right there; drag it out to put it anywhere again.
- **The panel** opens from the pill (hover for 2 seconds, or click): both
  meters with token counts, the model, a list of your sessions, and
  everything below.
- **The Touch Bar** turns into Claude's bar while your terminal or VS Code
  is in front: meters, your buttons, the model, the mic.

**Answer Claude**
- Permission requests: **Allow**, **Always allow**, **Deny** — from the
  Touch Bar, the notch or the panel. Answers go back through Claude Code's
  own hooks, not keystrokes.
- Questions (`AskUserQuestion`): tap an option, pick several, or type your
  own answer — on the Touch Bar you can even dictate it.
- If Clouding Bar isn't there to answer, Claude asks in its own UI as
  always. It never keeps Claude waiting.

**Talk to Claude**
- **Chat line** in the pill and the panel: write now, it's sent when
  Claude has finished its reply and its chat is in front.
- **Drop files** on the widget: they go to that project's chat with your
  next message.
- **Buttons** for your own phrases, slash commands, key presses and links,
  with global shortcuts and a set per project. **Templates** with
  `{project}`, `{branch}`, `{clipboard}`, `{date}`.
- **Dictation**: hold the right ⌥ key, or tap the mic.
- **Screenshot** an area of the screen straight into the chat.

**Steer it**
- Switch the **model and effort** from the panel or the Touch Bar.
- See which **subagents** are working and what each is doing right now.
- A warning when the **context** fills up, with one tap to `/compact` (or
  let it compact by itself).

**And**
- A seven-page **tour** on first launch (and from the menu) that plays out
  how everything works.
- **Everything is optional**: each number, detail and control has its own
  switch in Settings.
- **Stats**: your week in Claude Code, hour by hour, from local transcripts.
- **Cowork** chats can report their context through a small plugin.

<p align="center">
  <img src="docs/images/notch-question.png" width="420" alt="The notch grown for a question">
  <img src="docs/images/panel.png" width="420" alt="The panel with the subagents at work">
</p>
<p align="center">
  <img src="docs/images/touchbar.png" width="860" alt="The Touch Bar">
</p>

## Install

### Download

Get the latest `Clouding-Bar-<version>.dmg` from
[Releases](../../releases), open it and drag **Clouding Bar** into
Applications. It's signed and notarized by Apple.

On first launch it asks to **connect to Claude Code**: it adds a small hook
and a status line to `~/.claude/settings.json`. Your settings are merged,
never replaced, and backed up to `~/.cloudingbar/backups` first. Then the
tour opens.

### Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/nikolanaidenko-eng/clouding-bar
cd clouding-bar
make install
```

This builds the app into `~/Applications`, puts the hook programs in
`~/.cloudingbar` and registers them with Claude Code (merged, backed up).

### Permissions macOS asks for

| Permission | Why | |
|---|---|---|
| Accessibility | to type your buttons, templates and chat lines into Claude's chat | needed for those |
| Microphone, Speech Recognition | dictation | only if you dictate |
| Screen Recording | the screenshot button | only if you use it |

### VS Code

Claude's panel in VS Code doesn't run the status line, so the 5-hour limit
reaches Clouding Bar through a small wrapper instead: **Settings → General
→ 5-hour limit in VS Code → Set Up** (it sets
`claudeCode.claudeProcessWrapper`, keeping your settings file as it is).
New chats report the limit from then on.

## How it works

```
Claude Code ──hooks──▶ cloudingbar-hook ──unix socket──▶ Clouding Bar ──▶ pill · notch · panel · Touch Bar
     ▲                        │                               │
     └──── the answer ◀───────┘◀────── Allow / an option ─────┘
```

- Claude Code's [hooks](https://code.claude.com/docs/en/hooks) tell the app
  when a session starts and stops, when Claude works, which tools and
  subagents run, and when it needs a permission or an answer. For those,
  the hook waits for your choice and hands it back to Claude — or steps
  aside within two seconds if the app isn't running.
- The **status line** brings the 5-hour limit and the context; in VS Code,
  the wrapper does. The session's **transcript** adds the model, token
  counts and lines changed.
- The session shown is the one whose project is in the window in front.
- Buttons, templates and chat lines are typed into the chat in front, the
  way you would.

The protocol is written down in [docs/protocol.md](docs/protocol.md).

### Private by design

Clouding Bar talks only to Claude Code on your Mac. There is no account,
no analytics, no server. It never reads Claude Code's credentials.

The one exception is opt-in: **Settings → Cowork → Live limit via
claude.ai** reads your account-wide limit (desktop and Cowork chats
included) from claude.ai with your session key. The key stays in your
Keychain, behind a helper that answers only Clouding Bar, and goes only to
claude.ai, at most once a minute. That address isn't an official API and
may stop working.

## Settings

The menu bar icon → **Settings…**

- **General** — open at login, do not disturb, the Claude Code connection,
  the context warning, the dictation language, the tour.
- **Widget** — the pill, the notch, what it shows (a chip for each thing).
- **Touch Bar** — on or off, what it shows, with a live preview.
- **Buttons** — your buttons and their shortcuts, a set per project,
  templates.
- **Cowork**, **Stats**.

Everything is stored in `~/.cloudingbar/config.json`; every key is
optional.

<p align="center"><img src="docs/images/settings.png" width="560" alt="Settings"></p>

## Uninstall

1. Quit Clouding Bar (its menu bar icon → Quit) and delete it from Applications.
2. Remove the entries pointing to `~/.cloudingbar/cloudingbar-hook` from
   the `hooks` section of `~/.claude/settings.json`, and its `statusLine`
   (your previous status line command is in
   `~/.cloudingbar/statusline-original`).
3. In VS Code, remove `claudeCode.claudeProcessWrapper` if you set it up.
4. `rm -rf ~/.cloudingbar`

## Development

```sh
make            # build the app and the helpers into build/
make install    # …and install them
make test       # core checks
make snapshots  # every screen as PNGs in build/snapshots
make demo       # docs/demo.gif, recorded from the tour's scenes
make release    # universal, Developer ID-signed, notarized .dmg (see packaging/release.sh)
```

Plain `swiftc`, no Xcode project. Sources: `Sources/CloudingBar` (the app),
`Sources/CloudingBarHook` (the hook), `Sources/CloudingBarTap` (the VS Code
wrapper's tap), `Sources/CloudingBarKey` (the Keychain helper).

## Credits

Clouding Bar began as a fork of
[TouchMyBar/claudebar](https://github.com/TouchMyBar/claudebar) (MIT) — a
Touch Bar for Claude Code permission prompts. Thank you!

What changed since:

- Permissions and questions are answered through hooks, not keystrokes,
  and Claude never waits on the app.
- The floating widget: the pill, the notch, the panel, the island.
- The 5-hour limit, context, model, effort, subagents, lines, branch, cost.
- Questions with options and typed or dictated answers.
- Buttons with types, shortcuts and per-project sets; templates; the chat
  queue; file drop; screenshots; dictation.
- Model and effort switching; the subagents list; the sessions list.
- Cowork, Stats, the settings window and the tour.
- The "skip permissions" button is gone.

## License

MIT — see [LICENSE](LICENSE).

Clouding Bar is not affiliated with or endorsed by Anthropic. Claude is a
trademark of Anthropic, PBC.
