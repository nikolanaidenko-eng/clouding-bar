# Clouding Bar: submitting the plugin to Anthropic's directory

> **Not submitted (owner, 30.10): the app's claude.ai sign-in goes against Anthropic's terms for third-party apps.**
> The plugin stays on GitHub only, installed from its own marketplace, `nikolanaidenko-eng/clouding-bar`
> (`/plugin marketplace add nikolanaidenko-eng/clouding-bar`); it isn't listed in Anthropic's directory and the
> README and docs don't say it is. Anthropic's words, on
> [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance): "developers may not
> collect, store, or intermediate Claude.ai credentials or session tokens", and Anthropic "does not
> permit third-party developers to offer Claude.ai login into their own applications". The rest of this
> file is kept as reference only; if the sign-in is ever removed from the app, it is where to start.

Sources: https://claude.com/docs/directory/publish.md, https://claude.com/docs/plugins/submit.md,
https://claude.com/docs/plugins/pre-submission-checklist.md, https://claude.com/docs/plugins/platform-support.md

## Listing texts

- **Name:** Clouding Bar (plugin id `clouding-bar`)
- **Category:** Productivity (developer tools if offered)
- **Short description:** Every Claude Code chat on your Mac's Touch Bar, a floating pill or the notch; answer permissions and questions from there.
- **Long description:** Clouding Bar is a Mac menu bar app that shows what Claude is doing at a glance: which chats are working, which are done, how full the context and the 5-hour limit are. When Claude asks for a permission or a question, you answer from the Touch Bar, the pill or the notch, without switching windows. This plugin is the link between Claude and the app: its hooks hand each event to the app on your Mac, and `/clouding-bar:install` downloads the newest signed and notarized release from GitHub. No account, no analytics, no server. (Cowork tasks show in the Mac app through its own optional claude.ai sign-in, not through this plugin; the plugin never talks to claude.ai.)
- **Works in:** Claude Code (Mac). In Cowork it only helps install the Mac app (its guide); Cowork's tasks reach the app through the app's own claude.ai sign-in. Hooks are ignored in Chat (platform-support table), so Chat gets nothing from it.
- **Repository:** https://github.com/nikolanaidenko-eng/clouding-bar, plugin path `plugin`, branch `main`. License: MIT.
- **Icon:** `plugin/.claude-plugin/icon.png` (1024x1024, from the app icon).

## Screenshots (docs/images/)

touchbar.png, touchbar-permission.png, pill.png, notch-question.png, panel.png, stats.png, settings.png (optional: tour.png, touchbar-short.png, demo.gif).

## Data handling answers (from the README's "Private by design" and docs/privacy.md)

- **Reads or stores personal data?** Chat titles and status of the user's own Claude sessions, kept locally in `~/.cloudingbar` on the user's Mac. Never reads Claude Code credentials.
- **Sends data elsewhere than declared connectors?** No server of ours, no analytics. Exceptions, all user-visible: (1) once a day a plain request to GitHub's public releases list for the update check (can be switched off) and the download on install; (2) optional short chat names: the app runs the user's own `claude -p` with Haiku, so the chat title and first 400 letters of the first message go to Anthropic, same place the chat already goes (switchable off); (3) dictation uses on-device recognition, audio goes to Apple only if the user ticks "Allow sending audio to Apple" (off by default); (4) opt-in "claude.ai sign-in (limit, Cowork tasks and chats)": session key stays in Keychain, goes only to claude.ai; the app then reads the account's limit, chat list, Cowork task cards and events, and sends what the user sends from the bar. These are unofficial addresses, listed in docs/privacy.md. The plugin itself never talks to claude.ai.
- **Retention:** local files only, removed by the Uninstall steps in the README; nothing is retained by us.
- **For people under 18?** No, a developer tool, not aimed at minors.

## Known review risks (the safety scan and a reviewer look at these)

1. `plugin/hooks/run.sh` execs `~/.cloudingbar/cloudingbar-hook`, a program outside the plugin, and reads `~/.claude/settings.json` (to step aside). Expect a "held for a reviewer" finding. README explains it.
2. `scripts/install-app.sh` downloads and installs an app from GitHub (verifies Developer ID signature and notarization). Same: explain in the review notes.
3. The plugin sits in a subfolder (`plugin/`) and `run.sh` uses shell variables and `$(...)`, so "Scripts the validator couldn't follow" holds the version for a reviewer (a hold, not a block; the hook commands themselves name only `${CLAUDE_PLUGIN_ROOT}/hooks/run.sh`, which is allowed). The doc's remedy is a plugin at its own repository root; not done.

5. The Mac app (not the plugin) signs in to claude.ai with a session key and uses unofficial addresses, sending messages as the web client does (`web_claude_ai`), with a warning before the sign-in since 1.2.21. Policy §3F (own or control the endpoints your Software connects to) and §1G (chat history) could be read against it, though the plugin itself doesn't connect there. Disclosed in docs/privacy.md and in the data handling answers; not hidden. A reviewer may ask for changes or reject; a rejected submission can be resubmitted.

## What the owner clicks

**The repository is fixed at submission:** "You can't change a submission's repository and folder after you submit. To list a plugin from a different repository or folder, create a new submission." So the repository moved to the `wvnikola` organization first (29.10).

Checked 30.10 on 1.2.20: `claude plugin validate plugin` and the marketplace pass; no `.DS_Store`, no file over 256 KiB, no `!` lines in commands or skills.

1. Needs a Pro/Max/Team/Enterprise claude.ai account; connect GitHub in claude.ai (account with push rights to nikolanaidenko-eng/clouding-bar).
2. Push this branch to `main` first (the directory reads the repository; it must be public before going live).
3. Open https://claude.ai/directory/manage, **Submit new**, **Plugin bundle**.
4. Source: repository `nikolanaidenko-eng/clouding-bar`, plugin path `plugin`, branch empty (default). **Validate**; fix anything marked Blocks.
5. Check Listing details; Data handling: answers above; Compliance: contact email, tick all four acknowledgements.
6. Review and submit: keep **GitHub push webhook**; **Submit for review**. Then watch status in **Submissions**; when it passes, **Publish** (a reviewer publishes it).
7. Fee: none mentioned in the docs; review time "isn't fixed".

## Desktop Extension (.mcpb)

Not suitable. Clouding Bar has no MCP server, and the directory states: "Desktop extension listings in the directory are deprecated, and the directory no longer accepts local MCP servers packaged as desktop extensions (MCPB)." Settings → Connectors is for MCP servers, so a plugin will not appear there.
