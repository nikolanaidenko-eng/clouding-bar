# Clouding Bar in OpenAI's Codex plugin directory

Checked 27.10.2026 against OpenAI's pages (links below) and `codex-cli 0.164.0`.
Nothing has been submitted.

## The blocker

The plugin works through **lifecycle hooks** (`codex-plugin/hooks/hooks.json`):
that is how Codex tells the app about sessions, permission requests, subagents.
OpenAI's pages say:

- "Plugins with lifecycle hooks aren't eligible for the public plugin directory."
  ([Build plugins, Hooks](https://developers.openai.com/codex/plugins/build))
- "Plugin ZIP packages containing app references (`apps` / `.app.json`) or lifecycle hooks cannot currently be submitted." and "Remove lifecycle hooks before public directory submission."
  ([Submit plugins](https://developers.openai.com/plugins/deploy/submission))
- Hooks "can be installed manually in Codex desktop"
  ([Submit your Claude Code plugin](https://developers.openai.com/plugins/guides/submit-claude-plugin.md)).

So **the plugin as it is can't go into the official directory today**. Without
hooks the app gets nothing from Codex (it would still read `~/.codex/sessions`
files, but no permission answers from the bar, no Esc at once).

What can go in: a **skills-only** plugin (the `install-app` skill alone; no
hooks, no MCP). It would only install the app; the link would stay Connect or
this repo's marketplace. Because the skill runs a local script and downloads
a program, OpenAI may treat it as a *desktop-only* plugin: "Local MCP
submissions are restricted to approved partners… allowlisted by your OpenAI
representative"; "Contact your OpenAI partner before submitting if the core
value requires local execution, arbitrary file access on the user's computer,
hardware or application access…"
([Desktop-only plugins](https://developers.openai.com/plugins/deploy/desktop-only)).
The docs do not say whether a skills-only plugin with a shell script counts;
that question goes to OpenAI first. Recommendation: keep distributing through
this repo's marketplace (`codex plugin marketplace add nikolanaidenko-eng/clouding-bar`),
ask OpenAI whether hooks plugins will be admitted, and submit a skills-only
version only if the answer is yes or it is wanted anyway.

## What is required to submit (any plugin)

From [Submit your Claude Code plugin to OpenAI](https://developers.openai.com/plugins/guides/submit-claude-plugin.md):

- "Get **Apps Management** write access in the owning OpenAI organization."
- "Complete individual or business identity verification."
- "Every plugin must complete OpenAI review."
- Portal: https://platform.openai.com/plugins → **Create plugin** → **Skills only** → upload the ZIP.
  The portal converts the manifest and "adds missing interface defaults and normalizes text fields."
- Test the skills "in a clean environment, confirming they find their files and executables and don't depend on undeclared packages, files, or credentials."
- Complete the listing and review fields, fix every scan result, submit.

Skills-only specifics ([Submit plugins](https://developers.openai.com/plugins/deploy/submission)):

- Needs `.claude-plugin/plugin.json` (or the Codex manifest) with a nonempty `description`, and at least one valid `skills/<name>/SKILL.md`.
- No MCP configuration (`.mcp.json`, `mcpServers`, `.app.json`, `apps`).
- "Skills-only plugins don't need MCP app review cases or a demo recording." So there are **no test cases** to write for it. (For MCP plugins there are review cases and a recording.)
- The four URLs (`websiteURL`, `supportURL`, `privacyPolicyURL`, `termsOfServiceURL`) are "Required for MCP review"; "Skills-only metadata validation doesn't require all four URLs." Give them anyway.
- "The dashboard requires a primary app icon before submission."
- "Required skill scans must finish successfully before you can submit."
- Skills should avoid Claude-only wording; use "the model".

**Fee and review time:** none of the pages above states a fee or a review time.
Nothing was found; ask OpenAI.

## Texts for the listing (skills-only version)

- Name: Clouding Bar
- Short description (≤ 80): Install Clouding Bar, the Mac app that shows Codex on your Touch Bar and notch.
- Long description: Clouding Bar is a free Mac app that shows your Codex and Claude Code chats at a glance — on the Touch Bar, in a floating pill or in the notch — and lets you answer permission requests from there. This plugin's skill installs the app: it downloads the newest release from GitHub, checks that it is signed with Clouding Bar's Developer ID (Team ID 8RFNMA23CG) and notarized by Apple, and puts it in Applications.
- Category: Productivity
- Developer: Nikola Naidenko
- Website / support / source: https://github.com/nikolanaidenko-eng/clouding-bar (issues: https://github.com/nikolanaidenko-eng/clouding-bar/issues)
- Privacy policy / terms: no page exists yet. The README section "Private by design" (https://github.com/nikolanaidenko-eng/clouding-bar#private-by-design) is the text; a standalone page is needed if the portal insists. Licence: MIT.
- Default prompt: "Install the Clouding Bar app on this Mac"
- Icon: `packaging/` / `tools/icon` has the app icon; a 512 px PNG is needed in `assets/`.

## Answers about privacy (from README "Private by design")

- Data collected by the plugin: none. No account, no analytics, no server of ours.
- The install skill makes requests to GitHub only: the public release list of this repository and the release download. Nothing about the user is sent.
- The app talks only to Claude Code and Codex on the user's Mac; it never reads their credentials (`auth.json` is never touched).
- Short chat names: for Claude chats only, via the user's own `claude -p` (Haiku); off in Settings; a Codex chat's words never go to Anthropic through it.
- Dictation: recognised on the Mac; audio goes to Apple only if the user ticks "Allow sending audio to Apple" (off by default).
- Update check: once a day, a plain request to GitHub's public releases list; can be turned off.
- Opt-in: live limit via claude.ai with the user's session key, kept in Keychain, sent only to claude.ai.
- Files touched on the Mac: `~/.cloudingbar` (app data, backups), and with Connect `~/.codex/hooks.json` (merged, backed up first).
- The skill runs a shell script, installs a signed program into /Applications (or ~/Applications), and opens it. Say this plainly in the listing.

## What the owner has to do

1. Decide: skip the directory for now (the repo marketplace already works), or ask OpenAI.
2. If asking: write to OpenAI (partner contact, or the developer forum thread
   "How can third-party community plugins be published to the Codex marketplace?") with two questions: are plugins with lifecycle hooks admitted, and may a skills-only plugin that runs a local install script be listed (desktop-only)?
3. For a skills-only submission: get Apps Management access and identity verification in the OpenAI organization; I can prepare the ZIP (`codex-plugin` without `hooks/`) when this is wanted.
4. Add a 512 px icon and, if the portal needs it, a privacy page.
5. In https://platform.openai.com/plugins: Create plugin → Skills only → Upload ZIP → fill the texts above → fix scan results → Submit.
