//! What the app knows: the sessions and limits (the core's Store), the
//! requests Claude is waiting on, and how each one is answered.

use cloudingbar_core::protocol::{self, Inbound};
use cloudingbar_core::requests::{Kind, Request};
use cloudingbar_core::store::{Activity, Store};
use interprocess::local_socket::SendHalf;
use serde::Serialize;
use serde_json::Value;
use std::io::Write;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime};

/// How long a request stays on the widget: in VS Code and the desktop app
/// Claude's own dialog is up at the same time (first answer wins), so long;
/// elsewhere Claude may be waiting on us, so briefly, renewed while you
/// interact (docs/protocol.md).
pub const PARALLEL_HOLD: u64 = 600;
pub const BLOCKING_HOLD: u64 = 15;

pub struct Pending {
    pub id: u64,
    pub request: Request,
    pub writer: Option<SendHalf>,
    pub hold_until: Instant,
}

#[derive(Default)]
pub struct State {
    pub store: Store,
    pub pending: Vec<Pending>,
    pub next_id: u64,
    pub front_title: Option<String>,
    /// The chat picked in the widget, and the one followed last: kept when
    /// the window in front can't tell which chat it shows.
    pub picked: Option<String>,
    pub last_followed: Option<String>,
    /// Following the chat at work (the macOS app's rule): after the chat
    /// shown finished, "done" for a moment, then the one still working —
    /// or, none working, back to the one in front. `front` is the chat the
    /// window in front showed then: another window ends it.
    pub handoff: Option<Handoff>,
    pub follow: Option<(String, String)>,
    pub last_shown: Option<(String, Activity)>,
    pub hooks_connected: bool,
    pub setup_message: Option<String>,
}

pub struct Handoff {
    pub done: String,
    pub next: String,
    pub until: Instant,
    pub front: String,
}

#[derive(Clone, Default)]
pub struct Shared(pub Arc<Mutex<State>>);

impl Shared {
    pub fn lock(&self) -> MutexGuard<'_, State> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl State {
    /// A request arrived: hold it (the hook gives up after 2 s without
    /// this) and keep the way back to the hook. Returns its id, or None
    /// when it was passed at once.
    pub fn add(&mut self, m: &Inbound, mut writer: SendHalf) -> Option<u64> {
        let Some(request) = Request::new(m) else {
            let _ = writer.write_all(protocol::pass().as_bytes());
            return None;
        };
        // In VS Code a question comes twice; it's answered from its
        // PermissionRequest, so the PreToolUse copy passes at once.
        if request.kind == Kind::Question && !request.via_permission && request.host_answers_in_parallel() {
            let _ = writer.write_all(protocol::pass().as_bytes());
            return None;
        }
        let hold = if request.host_answers_in_parallel() { PARALLEL_HOLD } else { BLOCKING_HOLD };
        if writer.write_all(protocol::hold(hold).as_bytes()).is_err() {
            return None;
        }
        self.next_id += 1;
        let id = self.next_id;
        self.pending.push(Pending { id, request, writer: Some(writer), hold_until: Instant::now() + Duration::from_secs(hold) });
        Some(id)
    }

    /// Sends the final answer (or "no decision") and forgets the request.
    pub fn finish(&mut self, id: u64, output: Option<Value>) {
        if let Some(i) = self.pending.iter().position(|p| p.id == id) {
            let mut p = self.pending.remove(i);
            if let Some(w) = p.writer.as_mut() {
                let line = output.map(|o| protocol::output(&o)).unwrap_or_else(protocol::pass);
                let _ = w.write_all(line.as_bytes());
            }
        }
    }

    /// Claude moved on (its reply ended, a new prompt, the tool ran):
    /// whatever it was asking there is settled.
    pub fn moved_on(&mut self, m: &Inbound) {
        let Some(sid) = m.session_id() else { return };
        let event = m.event().unwrap_or("");
        let done: Vec<u64> = self.pending.iter().filter(|p| {
            p.request.session_id.as_deref() == Some(sid)
                && (matches!(event, "Stop" | "UserPromptSubmit" | "SessionEnd")
                    || (matches!(event, "PostToolUse" | "PostToolUseFailure") && m.tool_name() == Some(p.request.tool_name.as_str())))
        }).map(|p| p.id).collect();
        for id in done { self.finish(id, None); }
    }

    /// Holds that ran out go to Claude's own UI.
    pub fn expire(&mut self) {
        let now = Instant::now();
        let done: Vec<u64> = self.pending.iter().filter(|p| p.hold_until <= now).map(|p| p.id).collect();
        for id in done { self.finish(id, None); }
    }

    /// You're answering: a blocking request gets more time.
    pub fn touch(&mut self, id: u64) {
        if let Some(p) = self.pending.iter_mut().find(|p| p.id == id) {
            if !p.request.host_answers_in_parallel() {
                p.hold_until = Instant::now() + Duration::from_secs(BLOCKING_HOLD);
                if let Some(w) = p.writer.as_mut() {
                    let _ = w.write_all(protocol::hold(BLOCKING_HOLD).as_bytes());
                }
            }
        }
    }

    /// An answer from the widget: allow, always, deny, an option, the
    /// picked options of a multi-select, or typed text.
    pub fn answer(&mut self, id: u64, action: &str, index: Option<usize>, text: Option<String>) {
        let Some(p) = self.pending.iter_mut().find(|p| p.id == id) else { return };
        let output = match action {
            "allow" => Some(Request::allow()),
            "always" => Some(p.request.always()),
            "deny" => Some(Request::deny()),
            "option" | "send" | "other" => {
                let Some(q) = p.request.current().cloned() else { return };
                let answer = match action {
                    "option" => {
                        let Some(i) = index.filter(|i| *i < q.options.len()) else { return };
                        if q.multi_select {
                            if !p.request.picked.remove(&i) { p.request.picked.insert(i); }
                            None
                        } else {
                            Some(q.options[i].clone())
                        }
                    }
                    "send" => Some(p.request.picked.iter().map(|i| q.options[*i].clone()).collect::<Vec<_>>().join(", ")),
                    _ => {
                        let typed = text.unwrap_or_default();
                        let mut parts: Vec<String> = p.request.picked.iter().map(|i| q.options[*i].clone()).collect();
                        if !typed.trim().is_empty() { parts.push(typed.trim().to_string()); }
                        Some(parts.join(", "))
                    }
                };
                match answer {
                    Some(a) if !a.is_empty() => {
                        if p.request.answer_current(&a) { Some(p.request.answer_output()) } else { None }
                    }
                    _ => None,
                }
            }
            _ => return,
        };
        match output {
            Some(o) => self.finish(id, Some(o)),
            None => self.touch(id),
        }
    }

    /// The chat the widget follows: the one done a moment ago, the one at
    /// work it moved on to, else the window's (Store::focus).
    pub fn followed(&self, now: SystemTime) -> Option<&cloudingbar_core::store::Session> {
        let alive = |id: &String| self.store.sessions.get(id).filter(|s| s.is_alive(now));
        if let Some(s) = self.handoff.as_ref().and_then(|h| alive(&h.done)) { return Some(s); }
        if let Some(s) = self.follow.as_ref().and_then(|f| alive(&f.0)) { return Some(s); }
        self.front(now)
    }

    fn front(&self, now: SystemTime) -> Option<&cloudingbar_core::store::Session> {
        let sticky: Vec<String> = [self.picked.clone(), self.last_followed.clone()].into_iter().flatten().collect();
        self.store.focus(self.front_title.as_deref(), &sticky, now)
    }

    /// A chat picked in the widget: it, from now on.
    pub fn pick(&mut self, id: &str) {
        self.picked = Some(id.to_string());
        self.last_followed = Some(id.to_string());
        self.handoff = None;
        self.follow = None;
    }

    /// Once a second: the chat shown finished → "done" for 4 s, then on.
    pub fn update_following(&mut self) {
        let now = SystemTime::now();
        let key = self.store.in_window(self.front_title.as_deref(), now).map(|s| s.id.clone()).unwrap_or_default();
        let front = self.front(now).map(|s| (s.id.clone(), s.activity));
        if self.handoff.as_ref().is_some_and(|h| h.front != key) { self.handoff = None; }
        if let Some((id, at)) = &self.follow {
            let elsewhere = at != &key || front.as_ref().is_some_and(|(f, a)| f != id && *a != Activity::Sleep);
            if elsewhere { self.follow = None; }
        }
        if self.handoff.as_ref().is_some_and(|h| Instant::now() >= h.until) {
            let h = self.handoff.take().unwrap();
            let alive = self.store.sessions.get(&h.next).is_some_and(|s| s.is_alive(now));
            let in_front = front.as_ref().is_some_and(|(f, _)| f == &h.next);
            self.follow = if alive && !in_front { Some((h.next, key.clone())) } else { None };
        }
        if self.handoff.is_some() { return; }
        let Some((shown, activity)) = self.followed(now).map(|s| (s.id.clone(), s.activity)) else {
            self.last_shown = None;
            return;
        };
        let last = self.last_shown.replace((shown.clone(), activity));
        if !last.is_some_and(|(id, a)| id == shown && a == Activity::Work && activity == Activity::Sleep) { return; }
        let working = self.store.alive(now).into_iter()
            .filter(|s| s.id != shown && s.activity == Activity::Work)
            .max_by_key(|s| s.last_event).map(|s| s.id.clone());
        let next = working.or_else(|| front.filter(|(f, _)| f != &shown).map(|(f, _)| f));
        if let Some(next) = next {
            self.handoff = Some(Handoff { done: shown, next, until: Instant::now() + Duration::from_secs(4), front: key });
        }
    }

    /// Once a second: remember which chat that was.
    pub fn remember_followed(&mut self) {
        let id = self.followed(SystemTime::now()).map(|s| s.id.clone());
        if id.is_some() { self.last_followed = id; }
    }

    /// Claude waits on this chat: a request here, or a notice.
    fn waiting(&self, s: &cloudingbar_core::store::Session) -> bool {
        s.waiting_notice || self.pending.iter().any(|p| p.request.session_id.as_deref() == Some(s.id.as_str()))
    }

    /// What the widget shows, as plain data for the page.
    pub fn snapshot(&self) -> Snapshot {
        let now = SystemTime::now();
        let active = self.followed(now);
        let request = self.pending.iter()
            .find(|p| active.is_some_and(|a| p.request.session_id.as_deref() == Some(a.id.as_str())))
            .or_else(|| self.pending.first())
            .map(|p| RequestView::new(p, &self.store, active.map(|a| a.id.as_str())));
        let activity = if request.is_some() { Activity::Wait } else {
            active.map(|s| if s.waiting_notice { Activity::Wait } else { s.activity }).unwrap_or(Activity::Sleep)
        };
        Snapshot {
            has_session: active.is_some(),
            activity,
            project: active.and_then(|s| s.project_name()),
            session_percent: self.store.account.session_percent,
            reset: self.store.account.reset_long(now),
            reset_short: self.store.account.reset_short(now),
            week_percent: self.store.account.week_percent,
            context_percent: active.and_then(|s| s.context_percent()),
            model: active.and_then(|s| s.model_name()).map(|m| match active.and_then(|s| s.effort.clone()) {
                Some(e) => format!("{m} · {e}"),
                None => m,
            }),
            chat_name: active.map(|s| s.display_name()),
            chat_color: active.map(|s| s.color_hex()),
            chat_place: active.map(place),
            chat_status: active.map(|s| status(s, self.waiting(s), now)),
            chat_done: active.is_some_and(|a| self.handoff.as_ref().is_some_and(|h| h.done == a.id)),
            sessions: {
                let mut list: Vec<SessionView> = self.store.alive(now).iter().map(|s| SessionView {
                    id: s.id.clone(),
                    name: s.display_name(),
                    activity: if self.waiting(s) { Activity::Wait } else { s.activity },
                    context: s.context_percent(),
                    color: s.color_hex(),
                    current: active.is_some_and(|a| a.id == s.id),
                    waiting: self.waiting(s),
                    place: place(s),
                    status: status(s, self.waiting(s), now),
                }).collect();
                // A steady order, so the tabs don't jump about.
                let order: std::collections::HashMap<&str, usize> =
                    self.store.sessions.values().map(|s| (s.id.as_str(), s.color)).collect();
                list.sort_by(|a, b| (order.get(a.id.as_str()), &a.id).cmp(&(order.get(b.id.as_str()), &b.id)));
                list
            },
            request,
            hooks_connected: self.hooks_connected,
            setup_message: self.setup_message.clone(),
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub has_session: bool,
    pub activity: Activity,
    pub project: Option<String>,
    pub session_percent: Option<f64>,
    pub reset: Option<String>,
    pub reset_short: Option<String>,
    pub week_percent: Option<f64>,
    pub context_percent: Option<f64>,
    pub model: Option<String>,
    /// The chat shown: its title (or project), colour, where it runs, what it does.
    pub chat_name: Option<String>,
    pub chat_color: Option<String>,
    pub chat_place: Option<String>,
    pub chat_status: Option<String>,
    /// The chat shown just finished; the widget moves on in a moment.
    pub chat_done: bool,
    pub sessions: Vec<SessionView>,
    pub request: Option<RequestView>,
    pub hooks_connected: bool,
    pub setup_message: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
    pub id: String,
    pub name: String,
    pub activity: Activity,
    pub context: Option<f64>,
    pub color: String,
    pub current: bool,
    pub waiting: bool,
    pub place: String,
    pub status: String,
}

/// "GitHub · VS Code": its project, if it has a title, and where it runs.
fn place(s: &cloudingbar_core::store::Session) -> String {
    let source = match s.entrypoint.as_deref() {
        Some("claude-vscode") => "VS Code",
        Some("cli") => "Terminal",
        Some("claude-desktop") => "Desktop",
        _ => "Claude Code",
    };
    match (&s.title, s.project_name()) {
        (Some(_), Some(p)) => format!("{p} · {source}"),
        _ => source.to_string(),
    }
}

/// "Needs your OK", "Working · 3 min", "Done · your turn", "Idle · 12 min".
fn status(s: &cloudingbar_core::store::Session, waiting: bool, now: SystemTime) -> String {
    let minutes = |t: SystemTime| now.duration_since(t).unwrap_or_default().as_secs() / 60;
    let span = |m: u64| if m >= 60 { format!("{} h", m / 60) } else { format!("{m} min") };
    if waiting { "Needs your OK".into() }
    else if s.activity == Activity::Work { format!("Working · {}", span(minutes(s.activity_since))) }
    else if s.finished_at.is_some_and(|t| minutes(t) < 15) { "Done · your turn".into() }
    else { format!("Idle · {}", span(minutes(s.last_event))) }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestView {
    pub id: u64,
    pub kind: &'static str,
    pub project: Option<String>,
    /// The chat it comes from, its colour, and whether that's another chat
    /// than the one shown.
    pub chat: Option<String>,
    pub chat_color: Option<String>,
    pub elsewhere: bool,
    pub verb: String,
    pub detail: String,
    pub question: Option<String>,
    pub options: Vec<String>,
    pub descriptions: Vec<String>,
    pub multi_select: bool,
    pub picked: Vec<usize>,
    pub index: usize,
    pub count: usize,
}

impl RequestView {
    fn new(p: &Pending, store: &Store, shown: Option<&str>) -> Self {
        let r = &p.request;
        let (verb, detail) = r.summary();
        let q = r.current();
        let session = r.session_id.as_ref().and_then(|id| store.sessions.get(id));
        RequestView {
            id: p.id,
            kind: if r.kind == Kind::Question { "question" } else { "permission" },
            project: session.and_then(|s| s.project_name()),
            chat: session.map(|s| s.display_name()),
            chat_color: session.map(|s| s.color_hex()),
            elsewhere: session.is_some_and(|s| Some(s.id.as_str()) != shown) && store.sessions.len() > 1,
            verb,
            detail,
            question: q.map(|q| q.text.clone()),
            options: q.map(|q| q.options.clone()).unwrap_or_default(),
            descriptions: q.map(|q| q.descriptions.clone()).unwrap_or_default(),
            multi_select: q.is_some_and(|q| q.multi_select),
            picked: r.picked.iter().copied().collect(),
            index: r.index,
            count: r.questions.len(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use interprocess::local_socket::{prelude::*, GenericNamespaced, ListenerOptions, Stream};
    use std::io::{BufRead, BufReader};

    /// The chat shown finished while another works: "done" first, then
    /// that one; another window in front ends it.
    #[test]
    fn follows_the_chat_at_work() {
        let mut st = State::default();
        let now = SystemTime::now();
        let ev = |e: &str, id: &str| Inbound::parse(format!(
            r#"{{"hook_event_name":"{e}","session_id":"{id}","cwd":"/p/{id}"}}"#).as_bytes()).unwrap();
        st.store.apply(&ev("UserPromptSubmit", "a"), now);
        st.store.apply(&ev("UserPromptSubmit", "b"), now);
        st.front_title = Some("a — Visual Studio Code".into());
        st.update_following();
        assert_eq!(st.followed(now).map(|s| s.id.clone()).as_deref(), Some("a"));
        st.store.apply(&ev("Stop", "a"), now);
        st.update_following();
        assert!(st.snapshot().chat_done, "a is shown as done first");
        st.handoff.as_mut().unwrap().until = Instant::now();
        st.update_following();
        assert_eq!(st.followed(now).map(|s| s.id.clone()).as_deref(), Some("b"), "then b, still at work");
        st.front_title = Some("b — Visual Studio Code".into());
        st.update_following();
        assert!(st.follow.is_none(), "another window in front: following it again");
    }

    /// A request held, then answered from the widget: the hook gets the hold
    /// at once and the decision after.
    #[test]
    fn holds_then_answers() {
        let name = format!("cb-state-{}.sock", std::process::id());
        let listener = ListenerOptions::new().name(name.as_str().to_ns_name::<GenericNamespaced>().unwrap())
            .create_sync().unwrap();
        let client = Stream::connect(name.as_str().to_ns_name::<GenericNamespaced>().unwrap()).unwrap();
        let (_recv, send) = listener.accept().unwrap().split();
        let mut lines = BufReader::new(client);

        let mut st = State::default();
        let m = Inbound::parse(br#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"},"claude_entrypoint":"cli"}"#).unwrap();
        let id = st.add(&m, send).unwrap();
        let mut line = String::new();
        lines.read_line(&mut line).unwrap();
        assert_eq!(line.trim(), r#"{"hold":15}"#, "a blocking request is held briefly");
        assert_eq!(st.snapshot().request.unwrap().verb, "Run");

        st.answer(id, "allow", None, None);
        line.clear();
        lines.read_line(&mut line).unwrap();
        assert!(line.contains(r#""behavior":"allow""#), "{line}");
        assert!(st.pending.is_empty());
    }

    /// Claude moved on: the card goes, the hook hears "no decision".
    #[test]
    fn claude_moving_on_settles_it() {
        let name = format!("cb-moved-{}.sock", std::process::id());
        let listener = ListenerOptions::new().name(name.as_str().to_ns_name::<GenericNamespaced>().unwrap())
            .create_sync().unwrap();
        let client = Stream::connect(name.as_str().to_ns_name::<GenericNamespaced>().unwrap()).unwrap();
        let (_recv, send) = listener.accept().unwrap().split();
        let mut lines = BufReader::new(client);
        let mut st = State::default();
        let m = Inbound::parse(br#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{},"claude_entrypoint":"claude-vscode"}"#).unwrap();
        st.add(&m, send).unwrap();
        let mut line = String::new();
        lines.read_line(&mut line).unwrap();
        assert_eq!(line.trim(), r#"{"hold":600}"#, "VS Code answers alongside: held long");
        st.moved_on(&Inbound::parse(br#"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Bash"}"#).unwrap());
        line.clear();
        lines.read_line(&mut line).unwrap();
        assert_eq!(line.trim(), r#"{"pass":true}"#);
        assert!(st.pending.is_empty());
    }
}
