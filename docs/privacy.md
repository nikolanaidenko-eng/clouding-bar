# Private by design

What leaves your Mac, where to, how often, and what is kept on it. The [README](../README.md) has the short version.

Clouding Bar talks to Claude Code on your Mac. It has no account of its own,
no analytics and no server, and it never reads Claude Code's credentials. Its
only talk with claude.ai is the optional [sign-in below](#the-claudeai-sign-in-optional),
off until you use it, and it goes against Anthropic's terms.

**Short chat names.** To keep a chat's name short enough for a button, the
app asks Claude Code's own small model (Haiku), once per chat, for a name of
one to three words. For that it runs your own `claude -p` (no tools, no hooks,
nothing saved), and the chat's title and the first 400 letters of its first
message go to Anthropic through it — the same place the chat itself already
goes. The name is kept in `~/.cloudingbar/names`, and Claude Code is handed
it as the chat's title (the next time you write in the chat, by the hook)
unless you have named the chat yourself. It never replaces a name you gave.
To switch it off, Settings → General → App → More… → Short chat names (or
`"shortNames": false` in `~/.cloudingbar/config.json`): no call is made, the bar cuts a long title with "…", and the hook stops
handing names back. Only Claude chats are named — a Codex chat's words never
go to Anthropic through this. A name already handed to a Claude Code tab stays
in that chat after you switch the setting off.

**The start of an answer.** When a chat is done, Cloud and the Touch Bar say
how its answer begins. The answer's text comes from where the app already
listens — Claude Code's Stop hook (`last_assistant_message`), Codex's session
file, a Cowork task's events — and is kept in memory only, never written to
disk or to the log. On macOS 26 with Apple Intelligence, Apple's own model
retells it in a sentence (marked ✦) on this Mac: nothing leaves it, no account,
no network. Elsewhere you see its first lines. To switch it off, Settings →
Widget → More… → Start of the answer (or `"answerPreview": false` in
`~/.cloudingbar/config.json`). A long question on the Touch Bar is put shorter
(✦) by the same model, the same way.

Three exceptions. **Dictation** is recognised on your Mac; only for a
language your Mac can't do offline, and only if you tick *Allow sending audio
to Apple* (off by default, Settings → General → App), your voice goes to
Apple's servers for recognition. The **update check**: once a day a plain request to
GitHub's public list of this project's releases — nothing about you, no
identifier — and the download, when you install one (Settings → General →
App → More… → Updates turns the check off). And, off until you sign in, the
**claude.ai sign-in**, below.

## The claude.ai sign-in (optional)

> **Against Anthropic's terms — use it at your own risk.** Anthropic's terms
> don't allow third-party apps to collect or store claude.ai session keys, or
> to reach claude.ai automatically. Signing in here goes against them and
> could put your account at risk, including suspension. Anthropic hasn't
> approved Clouding Bar. Without this sign-in everything else keeps working,
> except Cowork tasks, claude.ai chats, the account-wide limit and sending to
> a Claude Desktop or Terminal chat through Remote Control without switching
> windows.
>
> Anthropic's words: in [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance),
> "developers may not collect, store, or intermediate Claude.ai credentials or
> session tokens", and Anthropic does not permit third-party developers "to
> offer Claude.ai login into their own applications"; [Logging in to your
> Claude account](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account)
> rules out third-party tools "that misrepresent their identity to Anthropic's
> servers"; the [Consumer Terms](https://www.anthropic.com/legal/consumer-terms)
> rule out access "through automated or non-human means, whether through a
> bot, script, or otherwise". The app says so before you sign in (**I
> Understand**), and once, at the first launch of 1.2.21, to those who were
> already signed in (**Keep Signed In** or **Sign Out**).

**Settings → General → Claude → claude.ai → Sign In…**: the app then
reads your account's limit, Cowork tasks and chats from claude.ai, and sends
what you send from the widget or the bar to a Cowork task, a claude.ai chat,
or a Claude Desktop or Terminal Claude Code chat with Remote Control on. Only to claude.ai, with the session
key as a cookie, never following redirects. The addresses are unofficial:
not a documented API, but the ones claude.ai's own pages use, and they may
stop working at any time. Its messages to chats name claude.ai's web client
(`anthropic-client-platform: web_claude_ai`), as the page does, and the sign-in
window identifies as Safari, because some sign-ins turn away an app's web view.
The other requests carry the system's own User-Agent. The requests:

- `/api/organizations` — once;
- `/api/organizations/{org}/usage` — every minute (the 5-hour and weekly limit);
- `/api/organizations/{org}/chat_conversations_v2` (or the older
  `chat_conversations`, if claude.ai doesn't know it) — every 5 s while a
  chat runs, waits or was active in the last two minutes, else every 15 s
  (names and states);
- `/v1/code/sessions?limit=1&tags=bard-conversation:{chat}` — for a chat active
  in the last half hour that isn't known as a Cowork task yet, at most once a
  minute (5 minutes once quiet): whether it is one;
- `/v1/code/sessions/{id}/events` — for a Cowork task that is running or just
  finished (context and model). This answer holds the task's messages too: the
  app keeps only the latest reply's model, token counts and text (for the
  start of the answer), in memory, and writes none of the messages to disk or
  to its log;
- `/v1/code/sessions/{id}` — for each Cowork task active in the last half hour,
  every 5 s while it works, waits for you or was just written to, else every
  15 s (whether it works, what it asks — the question or permission, shown on
  the bar — its context, its window, its cost and the tokens it has used so
  far, which Stats counts), and every 30 s for the
  Remote Control of a Claude Code chat in Claude Desktop or Terminal (whether
  it's on the line);
- POST `/claudeai-rpc/anthropic.bard.api.v1alpha.ConversationService/PerformAction`
  — only when you send words to a Cowork task or a claude.ai chat: your message,
  in the shape claude.ai's own page sends it, so the chat shows it. It says
  it comes from claude.ai's web client (`web_claude_ai`); if claude.ai turns it down, the words go the other
  way (a Cowork task's session, or typed into the window);
- POST `/v1/code/sessions/{id}/events` — only when you send: a message with a
  picture to a Cowork task, a message to a Remote Control chat, or your answer
  to what a task asks. Nothing else is written.

Sign In first shows the warning above and loads nothing until you press **I
Understand**. Then it opens a window with claude.ai's own sign-in pages (and
Google's or Apple's, if you sign in with one — Google's may refuse a window
that doesn't pose as a browser, which this one no longer does since 1.2.21),
in a browser store that is thrown away when the window closes; the pages see
the app's name (`CloudingBar/<version>`) after WebKit's own in the
User-Agent. Once you're signed in, the app takes the session key
from that page's cookie, keeps it only in the macOS Keychain and closes the
window. The key gives full access to your account; it never leaves your Mac
except to claude.ai. Signing in starts a new
login session on your account, as signing in anywhere does (claude.ai may
email you about it).

The names, states, model, context, a Cowork task's session id and window of the chats shown (those at work,
waiting for you or active in the last half hour; names up to 200 characters) are kept in
`~/.cloudingbar/sessions.json`, so the list is back after a restart; no
message text is kept. From the same card Stats counts a Cowork task's tokens
and working minutes by the hour; they are kept, with the task's name and model, in
`~/.cloudingbar/cowork-usage.json` (no message text either). **Sign Out**
deletes the key from your Mac and forgets these chats (the Stats numbers stay
until you remove `~/.cloudingbar`). The login session itself stays valid on claude.ai until it
expires; to end it at once, log out of all devices in claude.ai's settings.
A key pasted by hand in a version before 1.2.8 was given for the limit: it
reads the chats only once you say yes to the question 1.2.8 asks once.
These addresses aren't an official API and may stop working at any time.
