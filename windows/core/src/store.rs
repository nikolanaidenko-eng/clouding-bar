//! Sessions and the account's limits, kept from what arrives on the socket
//! (the same rules as the macOS app's SessionStore).

use crate::protocol::Inbound;
use crate::transcript;
use std::collections::HashMap;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// What Cloud shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Activity {
    /// Idle, or the turn finished.
    Sleep,
    /// Between your prompt and Claude's Stop.
    Work,
    /// Claude needs you: a permission, a question.
    Wait,
}

#[derive(Clone, Debug)]
pub struct Session {
    pub id: String,
    pub cwd: Option<String>,
    pub transcript_path: Option<String>,
    pub entrypoint: Option<String>,
    pub activity: Activity,
    pub activity_since: SystemTime,
    pub waiting_notice: bool,
    pub last_event: SystemTime,
    pub model: Option<String>,
    pub effort: Option<String>,
    /// From the status line (terminal sessions) …
    pub status_context_percent: Option<f64>,
    pub context_window_size: Option<u64>,
    /// … or from the transcript (the VS Code panel never runs it).
    pub context_tokens: Option<u64>,
    /// The chat's title ("Status bar"), from the transcript: VS Code's tab
    /// and the window title show the same.
    pub title: Option<String>,
    /// Its colour in the widget: an index into `COLORS`.
    pub color: usize,
    /// When Claude last finished a turn here (work → idle).
    pub finished_at: Option<SystemTime>,
}

/// One colour per chat, so two chats of one project are told apart; none
/// of them the orange of "needs you" (the macOS app's).
pub const COLORS: [u32; 8] = [0x0A84FF, 0xBF5AF2, 0x40C8E0, 0x30D158, 0xFF6EB4, 0xFFD60A, 0x7D7AFF, 0x63E6BE];

impl Session {
    fn new(id: &str, now: SystemTime) -> Self {
        Session {
            id: id.to_string(), cwd: None, transcript_path: None, entrypoint: None,
            activity: Activity::Sleep, activity_since: now, waiting_notice: false, last_event: now,
            model: None, effort: None, status_context_percent: None, context_window_size: None, context_tokens: None,
            title: None, color: 0, finished_at: None,
        }
    }

    /// What the widget calls it: its title, else its project.
    pub fn display_name(&self) -> String {
        self.title.clone().or_else(|| self.project_name()).unwrap_or_else(|| "Claude".into())
    }

    /// "#0A84FF".
    pub fn color_hex(&self) -> String { format!("#{:06X}", COLORS[self.color % COLORS.len()]) }

    /// The folder's name: "DiaRoute".
    pub fn project_name(&self) -> Option<String> {
        self.cwd.as_deref()
            .and_then(|c| c.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next())
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    }

    fn set_activity(&mut self, a: Activity, now: SystemTime) {
        if self.activity == Activity::Work && a == Activity::Sleep { self.finished_at = Some(now); }
        if self.activity != a {
            self.activity = a;
            self.activity_since = now;
        }
    }

    /// The context fill, 0…100: the status line's own number when there is
    /// one, else the transcript's tokens over the window.
    pub fn context_percent(&self) -> Option<f64> {
        if let Some(p) = self.status_context_percent {
            return Some(p);
        }
        let tokens = self.context_tokens? as f64;
        let window = self.context_window_size
            .unwrap_or_else(|| transcript::window_for(self.model.as_deref(), self.context_tokens.unwrap_or(0))) as f64;
        Some((tokens / window * 100.0).min(100.0))
    }

    /// "Opus 5.5 1M", from "claude-opus-5-5[1m]".
    pub fn model_name(&self) -> Option<String> { self.model.as_deref().map(display_name) }

    /// Twelve hours without news: gone, even if SessionEnd never came.
    pub fn is_alive(&self, now: SystemTime) -> bool {
        now.duration_since(self.last_event).unwrap_or_default() < Duration::from_secs(12 * 3600)
    }
}

/// "claude-opus-5-5[1m]" → "Opus 5.5 1M"; a date stamp is dropped.
pub fn display_name(id: &str) -> String {
    let big = id.contains("[1m]");
    let m = id.replace("[1m]", "").replace("claude-", "");
    let mut words: Vec<String> = Vec::new();
    for part in m.split('-') {
        let numeric = !part.is_empty() && part.chars().all(|c| c.is_ascii_digit());
        if let Some(last) = words.last_mut() {
            if numeric && part.len() <= 2 && last.starts_with(|c: char| c.is_ascii_digit()) && !last.contains('.') {
                last.push('.');
                last.push_str(part);
                continue;
            }
        }
        if numeric && part.len() >= 8 {
            continue; // a date stamp
        }
        let mut w = part.to_string();
        if let Some(f) = w.get_mut(0..1) {
            f.make_ascii_uppercase();
        }
        words.push(w);
    }
    words.join(" ") + if big { " 1M" } else { "" }
}

/// The account's limits: the 5-hour window and, on Pro and Max, the week.
#[derive(Clone, Debug, Default)]
pub struct Account {
    pub session_percent: Option<f64>,
    pub resets_at: Option<SystemTime>,
    pub week_percent: Option<f64>,
    pub week_resets_at: Option<SystemTime>,
    pub updated_at: Option<SystemTime>,
}

impl Account {
    /// Once a window has reset, its old number means nothing.
    pub fn expire(&mut self, now: SystemTime) {
        if self.resets_at.is_some_and(|r| r <= now) {
            self.session_percent = Some(0.0);
            self.resets_at = None;
        }
        if self.week_resets_at.is_some_and(|r| r <= now) {
            self.week_percent = Some(0.0);
            self.week_resets_at = None;
        }
    }

    /// "1:23" (hours:minutes) until the 5-hour window resets.
    pub fn reset_short(&self, now: SystemTime) -> Option<String> {
        let minutes = self.resets_at?.duration_since(now).unwrap_or_default().as_secs() / 60;
        Some(format!("{}:{:02}", minutes / 60, minutes % 60))
    }

    /// "1 h 23 min" until the 5-hour window resets.
    pub fn reset_long(&self, now: SystemTime) -> Option<String> {
        let minutes = self.resets_at?.duration_since(now).unwrap_or_default().as_secs() / 60;
        Some(if minutes >= 60 { format!("{} h {} min", minutes / 60, minutes % 60) } else { format!("{minutes} min") })
    }
}

fn time(seconds: f64) -> SystemTime { UNIX_EPOCH + Duration::from_secs_f64(seconds.max(0.0)) }

#[derive(Default)]
pub struct Store {
    pub sessions: HashMap<String, Session>,
    pub account: Account,
}

impl Store {
    /// Applies one socket message.
    pub fn apply(&mut self, m: &Inbound, now: SystemTime) {
        if let Some((used, resets)) = m.five_hour() {
            if let Some(u) = used { self.account.session_percent = Some(u); }
            if let Some(r) = resets { self.account.resets_at = Some(time(r)); }
            self.account.updated_at = Some(now);
        }
        if let Some((used, resets)) = m.seven_day() {
            if let Some(u) = used { self.account.week_percent = Some(u); }
            if let Some(r) = resets { self.account.week_resets_at = Some(time(r)); }
        }
        let Some(id) = m.session_id() else { return };
        if m.event() == Some("SessionEnd") {
            self.sessions.remove(id);
            return;
        }
        // Only hook events start a session; status messages just add numbers.
        if !self.sessions.contains_key(id) {
            if m.event().is_none() { return; }
            // The first colour no live chat has.
            let used: Vec<usize> = self.alive(now).iter().map(|s| s.color).collect();
            let color = (0..COLORS.len()).min_by_key(|c| (used.iter().filter(|u| *u == c).count(), *c)).unwrap_or(0);
            let mut new = Session::new(id, now);
            new.color = color;
            self.sessions.insert(id.to_string(), new);
        }
        let s = self.sessions.get_mut(id).unwrap();
        if let Some(v) = m.cwd() { s.cwd = Some(v.to_string()); }
        if let Some(v) = m.transcript_path() { s.transcript_path = Some(v.to_string()); }
        if let Some(v) = m.entrypoint() { s.entrypoint = Some(v.to_string()); }
        if let Some(v) = m.effort() { s.effort = Some(v.to_string()); }
        if let Some(v) = m.model_id() { s.model = Some(v.to_string()); }
        if let Some(v) = m.context_used_percent() { s.status_context_percent = Some(v); }
        if let Some(v) = m.context_window_size() { s.context_window_size = Some(v); }

        let Some(event) = m.event() else { return };
        s.last_event = now;
        match event {
            "SessionStart" | "Stop" => {
                s.set_activity(Activity::Sleep, now);
                s.waiting_notice = false;
            }
            "UserPromptSubmit" | "PreToolUse" | "PostToolUse" | "PostToolUseFailure" => {
                s.set_activity(Activity::Work, now);
                s.waiting_notice = false;
            }
            "Notification" => {
                let t = m.notification_type();
                if matches!(t, Some("permission_prompt") | Some("elicitation_dialog") | Some("agent_needs_input"))
                    || (t.is_none() && m.message().is_some_and(|x| x.to_lowercase().contains("permission")))
                {
                    s.waiting_notice = true;
                }
            }
            _ => {}
        }
    }

    /// Reads each live session's transcript for what hooks don't carry: the
    /// context fill and the model.
    pub fn poll_transcripts(&mut self) {
        for s in self.sessions.values_mut() {
            if let Some(path) = &s.transcript_path {
                if let Some(t) = transcript::latest(path) {
                    if let Some(c) = t.context_tokens { s.context_tokens = Some(c); }
                    if let Some(m) = t.model { s.model = Some(m); }
                    if let Some(title) = t.title { s.title = Some(title); }
                }
            }
        }
    }

    pub fn alive(&self, now: SystemTime) -> Vec<&Session> {
        let mut list: Vec<&Session> = self.sessions.values().filter(|s| s.is_alive(now)).collect();
        list.sort_by(|a, b| b.last_event.cmp(&a.last_event));
        list
    }

    /// The chat the window in front surely shows: by its title, or the
    /// only chat of its project. None when it can't be told.
    pub fn in_window(&self, window_title: Option<&str>, now: SystemTime) -> Option<&Session> {
        let parts = title_parts(window_title?);
        let alive = self.alive(now);
        let titled = |s: &Session| s.title.as_ref().is_some_and(|t| parts.iter().any(|p| p == t
            || (p.ends_with('…') && t.starts_with(p.trim_end_matches('…')))));
        if let Some(s) = alive.iter().find(|s| titled(s)) { return Some(*s); }
        let mine: Vec<&Session> = alive.iter().copied().filter(|s| s.project_name().is_some_and(|n| parts.contains(&n))).collect();
        if mine.len() == 1 { Some(mine[0]) } else { None }
    }

    /// The session the window in front shows, else the latest.
    pub fn active(&self, window_title: Option<&str>, now: SystemTime) -> Option<&Session> {
        self.focus(window_title, &[], now)
    }

    /// The chat the widget follows (the macOS app's rule): the one whose
    /// title the window in front shows ("Status bar — GitHub — Visual Studio
    /// Code"); else, of the chats of that window's project, the one in
    /// `sticky` (picked in the widget, or followed before), else the latest;
    /// no chat's window in front: the one in `sticky`, else the latest.
    pub fn focus(&self, window_title: Option<&str>, sticky: &[String], now: SystemTime) -> Option<&Session> {
        let alive = self.alive(now); // latest first
        if let Some(title) = window_title {
            let parts = title_parts(title);
            let score = |s: &Session| -> u8 {
                if s.title.as_ref().is_some_and(|t| parts.iter().any(|p| p == t
                    || (p.ends_with('…') && t.starts_with(p.trim_end_matches('…'))))) { 3 }
                else if s.project_name().is_some_and(|n| parts.contains(&n)) { 2 }
                else { 0 }
            };
            let best = alive.iter().map(|s| score(s)).max().unwrap_or(0);
            if best == 3 {
                return alive.iter().find(|s| score(s) == 3).copied();
            }
            if best == 2 {
                let mine: Vec<&Session> = alive.iter().filter(|s| score(s) == 2).copied().collect();
                return sticky.iter().find_map(|id| mine.iter().find(|s| &s.id == id).copied())
                    .or_else(|| mine.first().copied());
            }
        }
        sticky.iter().find_map(|id| alive.iter().find(|s| &s.id == id).copied()).or_else(|| alive.first().copied())
    }
}

/// A window title's pieces, without what decorates them ("● ", a terminal's
/// spinner, " (Workspace)").
pub fn title_parts(title: &str) -> Vec<String> {
    title.split(" — ").flat_map(|p| p.split(" – ")).flat_map(|p| p.split(" - "))
        .map(|p| p.replace(" (Workspace)", "").trim_start_matches(|c: char| !c.is_alphanumeric()).trim().to_string())
        .filter(|p| !p.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apply(store: &mut Store, s: &str, now: SystemTime) { store.apply(&Inbound::parse(s.as_bytes()).unwrap(), now) }

    #[test]
    fn names_models() {
        assert_eq!(display_name("claude-opus-5-5[1m]"), "Opus 5.5 1M");
        assert_eq!(display_name("claude-sonnet-4-5-20250929"), "Sonnet 4.5");
    }

    #[test]
    fn follows_a_session() {
        let mut st = Store::default();
        let t0 = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        apply(&mut st, r#"{"session_id":"x","rate_limits":{"five_hour":{"used_percentage":40}}}"#, t0);
        assert!(st.sessions.is_empty(), "a status line alone starts nothing");
        assert_eq!(st.account.session_percent, Some(40.0));
        apply(&mut st, r#"{"hook_event_name":"SessionStart","session_id":"x","cwd":"C:\\Users\\me\\DiaRoute"}"#, t0);
        apply(&mut st, r#"{"hook_event_name":"UserPromptSubmit","session_id":"x"}"#, t0);
        assert_eq!(st.sessions["x"].activity, Activity::Work);
        assert_eq!(st.sessions["x"].project_name().as_deref(), Some("DiaRoute"));
        apply(&mut st, r#"{"hook_event_name":"Notification","session_id":"x","notification_type":"permission_prompt"}"#, t0);
        assert!(st.sessions["x"].waiting_notice);
        apply(&mut st, r#"{"hook_event_name":"Stop","session_id":"x"}"#, t0);
        assert_eq!(st.sessions["x"].activity, Activity::Sleep);
        assert!(!st.sessions["x"].waiting_notice);
        apply(&mut st, r#"{"session_id":"x","context_window":{"used_percentage":31}}"#, t0);
        assert_eq!(st.sessions["x"].context_percent(), Some(31.0));
        apply(&mut st, r#"{"hook_event_name":"SessionEnd","session_id":"x"}"#, t0);
        assert!(st.sessions.is_empty());
    }

    #[test]
    fn picks_the_session_in_front() {
        let mut st = Store::default();
        let t0 = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        apply(&mut st, r#"{"hook_event_name":"SessionStart","session_id":"a","cwd":"/p/alpha"}"#, t0);
        apply(&mut st, r#"{"hook_event_name":"SessionStart","session_id":"b","cwd":"/p/beta"}"#, t0 + Duration::from_secs(5));
        assert_eq!(st.active(Some("main.rs — alpha — Visual Studio Code"), t0).unwrap().id, "a");
        assert_eq!(st.active(None, t0).unwrap().id, "b");
    }

    #[test]
    fn tells_two_chats_of_one_project_apart() {
        let mut st = Store::default();
        let t0 = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        apply(&mut st, r#"{"hook_event_name":"SessionStart","session_id":"a","cwd":"C:\\Users\\me\\GitHub"}"#, t0);
        apply(&mut st, r#"{"hook_event_name":"SessionStart","session_id":"b","cwd":"C:\\Users\\me\\GitHub"}"#, t0 + Duration::from_secs(5));
        st.sessions.get_mut("a").unwrap().title = Some("Status bar".into());
        st.sessions.get_mut("b").unwrap().title = Some("Сайт ordermeshop".into());
        assert_ne!(st.sessions["a"].color, st.sessions["b"].color, "each chat its own colour");
        assert_eq!(st.focus(Some("Status bar - GitHub - Visual Studio Code"), &[], t0).unwrap().id, "a", "by the chat's title");
        assert_eq!(st.focus(Some("main.rs - GitHub - Visual Studio Code"), &["a".into()], t0).unwrap().id, "a",
                   "on a file: the one followed before");
        assert_eq!(st.focus(Some("main.rs - GitHub - Visual Studio Code"), &[], t0).unwrap().id, "b", "else the latest");
        assert_eq!(st.focus(None, &["a".into()], t0).unwrap().id, "a", "nothing in front: the one followed");
        assert_eq!(st.sessions["a"].display_name(), "Status bar");
    }

    #[test]
    fn limits_expire_when_they_reset() {
        let mut a = Account { session_percent: Some(80.0), resets_at: Some(UNIX_EPOCH + Duration::from_secs(10)), ..Default::default() };
        a.expire(UNIX_EPOCH + Duration::from_secs(20));
        assert_eq!(a.session_percent, Some(0.0));
    }
}
