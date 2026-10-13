# ClaudeBar ✳

**Claude Code on your MacBook's Touch Bar.**

When a Claude Code session is running in your terminal, the Touch Bar
switches into *Claude mode*:

```
┌─────┬────┬───────────────┬────────────────────────────────────────────┐
│ esc │ ✳  │ ▲ 41k ▼ 2.3k  │   /code-review  /simplify   ⚡ skip perms  │
└─────┴────┴───────────────┴────────────────────────────────────────────┘
```

And when Claude asks for permission, the bar becomes the answer:

```
┌─────┬────┬──────────────────────────────┬────────────────────────────────┐
│ esc │ ✳  │ Claude needs your permission │ Allow Once │ Always Allow │ ✕  │
└─────┴────┴──────────────────────────────┴────────────────────────────────┘
```

When the session ends (or you switch away from your terminal), the bar
goes back to normal.

## Features

- **Permission prompts on the bar** — Allow Once / Always Allow / Reject,
  one tap each. Reject maps to Escape, just like in the terminal.
- **Skill shortcuts** — your most-used slash commands as buttons.
  Configure them in `~/.claudebar/config.json`.
- **Live usage** — a running token counter for the active session,
  straight from the session transcript.
- **`⚡ skip perms`** — types `claude --dangerously-skip-permissions` for
  you (without pressing Return — that part is on you, deliberately).
- **esc never leaves** — it's the only Esc this keyboard has, so it's
  always the leftmost button.
- **Works with the Claude desktop app too** — `com.anthropic.claudefordesktop`
  is in the default app list alongside the usual terminals.
- **A tiny Claude** — the ✳ starburst breathes on the bar while Claude
  works. That's the easter egg. Hi.

## Requirements

- A MacBook Pro with a Touch Bar (2016–2020 models), macOS 12+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- Xcode Command Line Tools (`xcode-select --install`) to build

## Install

```sh
git clone https://github.com/TouchMyBar/claudebar
cd claudebar
make install
```

The installer:

1. builds `ClaudeBar.app` and copies it to `~/Applications`
2. registers small [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)
   in `~/.claude/settings.json` (merged carefully — your existing hooks
   are untouched)
3. writes a starter config to `~/.claudebar/config.json`

On first launch, macOS asks for **Accessibility** access. ClaudeBar needs
it to press keys in your terminal when you tap a button — that's all it's
used for. Approve it in System Settings → Privacy & Security →
Accessibility.

## How it works

```
claude (terminal) ──hooks──▶ claudebar-relay.sh ──unix socket──▶ ClaudeBar.app
                                                                     │
                                              NSTouchBar ◀───────────┤
                                              keystrokes ───────────▶ terminal
```

- Claude Code's official **hooks** fire on session start/end, permission
  notifications, and turn completion. A 10-line shell script relays the
  hook JSON to ClaudeBar over a unix socket. If ClaudeBar isn't running,
  the relay is a no-op — your sessions are never affected.
- The bar only takes over while a **terminal app is frontmost** *and* a
  session is alive. The list of terminal apps is configurable.
- Buttons work by sending **keystrokes** to the frontmost app
  (`1` = allow once, `2` = always allow, Escape = reject), because Claude
  Code's prompts are keyboard-driven.

### The fine print on APIs

The Touch Bar UI is built entirely with official AppKit `NSTouchBar` API.
There is one exception, clearly contained in
[`SystemModalTouchBar.swift`](Sources/ClaudeBar/SystemModalTouchBar.swift):
Apple never shipped a public way for a background app to present on the
Touch Bar, so we use the same two stable-since-10.14 AppKit class methods
every Touch Bar customizer (Pock, MTMR, …) uses. They're looked up at
runtime and ClaudeBar simply does nothing if they ever disappear.

## Configuration

`~/.claudebar/config.json` — every key is optional:

```json
{
  "skills": ["/code-review", "/simplify", "/init"],
  "showUsage": true,
  "offerSkipPermissions": true,
  "terminalBundleIDs": ["com.apple.Terminal", "com.googlecode.iterm2"]
}
```

Restart ClaudeBar after editing (menu bar ✳ → Quit, then reopen).

## Known quirks

- macOS draws a small ✕ at the left edge of any system-modal Touch Bar.
  Tapping it hides ClaudeBar until the next event brings it back.
- The Allow/Always Allow buttons press `1`/`2` in your terminal. If a
  particular prompt orders its options differently, glance at the screen
  before tapping — or just use the keyboard for that one.
- Usage counts tokens from the session transcript, including cache reads,
  so it climbs faster than "billed tokens" would.

## Uninstall

```sh
rm -rf ~/Applications/ClaudeBar.app ~/.claudebar
```

Then remove the `claudebar-relay.sh` entries from the `hooks` section of
`~/.claude/settings.json`.

## License

MIT — see [LICENSE](LICENSE).
