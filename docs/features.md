# What Clouding Bar does

Everything it does, in full. The [README](../README.md) has the short version.

**See where you are**
- **Which chat.** Every chat gets its own colour and its own Cloud — ten of
  them, one in glasses, one a pirate, one with a crown — and a short name of
  a word or two that fits a button (VS Code's tab gets it too; a name you
  gave the chat yourself always wins), so two chats in one project are told
  apart at a glance. Clouding Bar follows the chat in front — VS
  Code's chat tab, a Terminal or iTerm tab — and stays with it when you
  switch to another app. With Claude Desktop in front, it's the chat open
  there. Pick another one in the widget, the menu or the Touch Bar, and
  it's brought up.
- **The chat at work.** When the chat shown finishes while another is still
  working, it says so — a tick, "Done · your turn" — and a moment later
  shows the one at work. Going to another window or tab, or picking a
  chat, puts you back in charge.
- **Another chat done.** When a chat other than the one shown finishes,
  Cloud pops out from behind the pill (or down from the notch) and says
  which — click it to go there — then ducks back; the Touch Bar says it
  too, with Open and OK. Quiet in do not disturb (Settings → Widget → More).
  It says how the answer begins, too: on macOS 26 with Apple Intelligence
  retold in a sentence by Apple's model on your Mac (marked ✦), else — and
  until the model is done — its first lines, without markdown or code.
- **The pill** floats over your windows: which chat, the 5-hour limit, the
  context, when the limit resets, the model, how long the chat has been at
  it, lines changed, the git branch, subagents. In Settings → Widget, pull
  its outline to resize it — wider shows more, taller stands it up as a
  column, pulled thinnest it keeps just the bars — drag items onto each
  other to swap them, and an item's right edge to make it wider or
  narrower. On screen it only moves, so a stray drag rearranges nothing.
- **The notch.** Drag the pill to the top of the screen and it docks in the
  notch, the numbers on either side of the camera. Macs without a notch get
  a drawn one. When Claude asks something, the notch grows so you can
  answer right there; drag it out to put it anywhere again.
- **The panel** opens from the pill with a click: your
  chats as tabs; the 5-hour limit and the context as two lines (the context
  as "312k of 1M"); the model, the time, lines, branch and subagents; and a
  message box that says which chat it writes to, Commands, the screenshot,
  the mic and Send on its line and your buttons under it; the gear opens
  Settings. There, its blocks move up or down by the bar over each, and the
  buttons swap places like the pill's items.
- **The Touch Bar** turns into Claude's bar while your terminal or VS Code
  is in front — or in every app, if you like (there the short bar, beside
  Apple's brightness and volume: a bar of its own, by default the chat's
  first letter, the limits, the chat line with your commands, the
  screenshot and the mic, and a button that opens the whole bar): which
  chat (tap it for the others; a name that doesn't fit ends in "…", and
  narrowed right down it's the first letter in the chat's colour), meters, the model,
  subagents, lines, branch, cost, **Write** (a message to the chat, typed
  or dictated, your buttons inside it), **Commands** with all your
  buttons, the mic — each one optional.
- **Arrange them your way.** Settings shows the widget and the Touch Bar
  themselves, live: drag a block to move it, its right edge to make it
  wider or narrower — on the Touch Bar it stops where something else would
  have to leave the bar. The short bar has its own list and fixed sizes —
  something in, something out; Settings says when there's no room.
- Limits are blue, orange from 70%, red from 90% — everywhere.

**Answer Claude**
- Permission requests: **Allow**, **Always allow**, **Deny** — from the
  Touch Bar, the notch or the panel, each saying which chat it comes from.
  Answers go back through Claude Code's own hooks, not keystrokes.
- Questions (`AskUserQuestion`): tap an option, pick several, or type your
  own answer — on the Touch Bar you can even dictate it.
- If Clouding Bar isn't there to answer, Claude asks in its own UI as
  always. It never keeps Claude waiting.

**Answer Cowork too**
- A question that Cowork (or any chat in Claude Desktop) asks in its window
  shows up on the Touch Bar and in the widget, and your pick is pressed
  there for you — read from the window, so the chat has to be open in
  Claude Desktop on the screen you're on.

**Talk to Claude**
- **Screenshot an area** of the screen straight into the chat: no
  ⌘⇧4, no file on the Desktop to find and drag in. Taken from another app,
  it's attached to the chat shown and goes with your next message — in VS
  Code as a picture.
- **Drop files** on the widget: they go to that project's chat with your
  next message.
- **Chat line** in the pill and the panel. In VS Code (with Settings →
  General → VS Code → Set Up) the message goes straight into the chat's
  Claude — wherever you are, no window switched — screenshots as pictures,
  and the chat shows it as yours. Elsewhere it waits in the queue until
  Claude has finished its reply and its chat is in front (or tap Send now).
- **Buttons** for your own phrases, slash commands, key presses and links,
  with global shortcuts and a set per project — in the row, and all of
  them behind **Commands** (one can be kept only there). A **text** button puts its words in the message for you to
  finish; `{project}`, `{branch}`, `{clipboard}` and `{date}` are filled in.
- **Dictation**: hold the right ⌥ key, or tap the mic. On macOS 26 and later
  it's the system's own dictation model, on this Mac: English gets its
  commas and full stops by itself; in Russian (whose model doesn't add
  them) say them — «запятая», «точка», «вопросительный знак». Pauses are fine:
  the widget shows the words as you speak, growing with them, then lets you
  check and edit them before you Send (or type them straight in, if you
  prefer — Settings → General → Voice).

**Steer it**
- Switch the **model and effort** from the panel or the Touch Bar.
- See which **subagents** are working and what each is doing right now.
- A warning when the **context** fills up, with one tap to `/compact` (or
  let it compact by itself).

**Codex too**
- Clouding Bar follows OpenAI's **Codex** as well, with nothing to set up:
  it reads Codex's own session files (`~/.codex/sessions`), so its chats
  show up with their 5-hour and weekly limits (while a Codex chat is in
  front), their context as Codex counts it, the model, and whether Codex is
  working or done — even when you stop it with Esc.
- **Connect** (Settings → General → Codex) adds Codex's hooks: permission
  requests answered from the bar, subagents, and Esc seen at once. Codex runs
  hooks only after you trust them — start Codex and choose *Trust all* (or
  `/hooks`). A hook added in a later version asks again, for itself only.
  Codex can't remember an "always allow", so there is none for it.
- **Live limits and sending** (Settings → General → Codex, on by default):
  Codex 0.164 runs one server of its own that every `codex` in a terminal
  uses, and while it runs Clouding Bar talks to it through
  `codex app-server proxy`.
  Codex's limits come as they are now (it asks its backend every few
  minutes), and the widget's words go straight into a chat the server has
  open, by the chat's id — no tab to find, nothing typed. While Codex works
  they wait in the queue and go when its turn ends; *Send now* adds them to
  the turn running. Nothing is started when no server runs, no chat is opened
  or copied, and Codex's approvals still come in its own window (and on the
  bar with Connect) — Clouding Bar approves nothing and holds no credentials.
- Not for Codex yet: its questions, the model picker, Stats, and words from
  the widget to a chat Codex's server doesn't have (VS Code's, the app's, an
  older Codex's): a chat known only from its files can't be told apart from a
  shell in the same folder, so nothing is typed.

**And**
- A **tour** on first launch (and behind the ? in Settings): what to
  connect where — Claude Code, VS Code, claude.ai for Cowork (optional, at
  your own risk), Codex — then
  the widget, the Touch Bar and your buttons. It dims the settings window but
  for one thing at a time, a card says what it does, and Cloud hops onto it.
- **Everything is optional**: each number, detail and control has its own
  switch in Settings. What most people need is up front; the rest waits
  behind **More**.
- **Stats**, the way Claude Code's /stats puts them: both limits; for the
  week, the month or everything, your sessions, active time, tokens and
  days in a row, your favourite model and peak hour; every day of the last
  half year as a square (point at one to see it); the projects the time
  went to. From local transcripts, kept after Claude Code clears old ones.
  Cowork tasks count too, from their cards on claude.ai once you're signed
  in (tokens counted as for Claude Code; time while a task is working), from
  version 1.2.20 on. What older versions reported stays.
- **Cowork** tasks and claude.ai / Claude Desktop chats show up too, through
  your claude.ai account: Settings → General → Claude → claude.ai →
  **Sign In…** (it goes against Anthropic's terms for third-party apps, at
  your own risk: [privacy.md](privacy.md#the-claudeai-sign-in-optional)).
  The chats list shows each one's name and whether it's
  working, done or waiting for you (a permission or a question); for Cowork
  tasks also the context and the model. Click one to open it in Claude
  Desktop. A Cowork task's questions and permissions come to the bar, and
  your messages go to it through claude.ai — whatever Claude Desktop shows
  in front, and shown in its chat as if typed there (pictures reach Claude,
  but don't show in the chat yet). Words go the same way to a plain claude.ai
  chat; and to a Claude Code chat in Claude Desktop or Terminal
  with Remote Control on (`/remote-control`, or `"remoteControlAtStartup": true`
  for every new one). The account-wide 5-hour and weekly limit come with it (Desktop,
  Cowork and claude.ai chats count too). No plugin, no connected folder,
  nothing asked of Claude, no extra tokens.
- **Keeps itself up to date**: once a day it looks on GitHub for a newer
  release and offers it — one click, checked before it's installed.

<p align="center">
  <img src="images/notch-question.png" width="420" alt="The notch grown for a question">
  <img src="images/panel.png" width="420" alt="The panel with the subagents at work">
</p>
<p align="center">
  <img src="images/touchbar.png" width="860" alt="The Touch Bar">
  <img src="images/touchbar-short.png" width="538" alt="The short Touch Bar beside Apple's buttons: the chat's letter, the limits, the chat line with your commands, the screenshot, the mic">
  <img src="images/touchbar-permission.png" width="860" alt="The Touch Bar asking, with the chat it comes from">
</p>

## Settings

The menu bar icon → **Settings…** Light or dark, as macOS is or as you pick.
Cloud keeps you company there: it sits in the corner, hops from row to row
as you move the pointer, and walks along the tabs.

- **General** — each box shows two or three main rows, the rest behind
  More…: open at login (and with Claude), do not disturb, the dictation
  language, appearance (auto, light, dark), short chat names, colourful or
  grey buttons, updates; Claude (the Claude Code connection, the 5-hour limit
  in VS Code, claude.ai for Cowork and the limit); Codex in a box of
  its own (its hooks, live limits and sending); the context warning.
- **Widget** — the widget itself on top, the pill or the panel, to arrange
  right there; show it, in the notch; behind More: follow the chat at work,
  tell when another chat is done and the start of its answer, keep the pill
  visible, its position; what it shows (a chip
  for each thing).
- **Touch Bar** — the bar itself on top, the whole one and the short one,
  each with what it shows (everything the widget can, and Write and
  Commands): drag a block to move it, on the whole bar its right edge to
  size it; on or off, in every app or only Claude's, short or whole outside
  Claude.
- **Buttons** — your buttons and their shortcuts, a set per project, shown
  on the Touch Bar as you edit them; Commands lists them all, and one can
  be kept only there, out of the row.
- **Stats** — see above.

Everything is stored in `~/.cloudingbar/config.json`; every key is
optional.

<p align="center">
  <img src="images/settings.png" width="420" alt="Settings: the widget itself, to arrange">
  <img src="images/tour.png" width="420" alt="The tour">
</p>
<p align="center">
  <img src="images/stats.png" width="600" alt="Stats: both limits, sessions, active time, tokens, streak, every day as a square">
</p>
