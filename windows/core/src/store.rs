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
}

impl Session {
    fn new(id: &str, now: SystemTime) -> Self {
        Session {
            id: id.to_string(), cwd: None, transcript_path: None, entrypoint: None,
            activity: Activity::Sleep, activity_since: now, waiting_notice: false, last_event: now,
            model: None, effort: None, status_context_percent: None, context_window_size: None, context_tokens: None,
        }
    }

    /// The folder's name: "DiaRoute".
    pub fn project_name(&self) -> Option<String> {
        self.cwd.as_deref()
            .and_then(|c| c.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next())
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    }

    fn set_activity(&mut self, a: Activity, now: SystemTime) {
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
            self.sessions.insert(id.to_string(), Session::new(id, now));
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
                    s.context_tokens = Some(t.context_tokens);
                    if let Some(m) = t.model { s.model = Some(m); }
                }
            }
        }
    }

    pub fn alive(&self, now: SystemTime) -> Vec<&Session> {
        let mut list: Vec<&Session> = self.sessions.values().filter(|s| s.is_alive(now)).collect();
        list.sort_by(|a, b| b.last_event.cmp(&a.last_event));
        list
    }

    /// The session whose project the window in front shows (its title has
    /// the folder's name as one of its " — " / " - " parts), else the latest.
    pub fn active(&self, window_title: Option<&str>, now: SystemTime) -> Option<&Session> {
        let alive = self.alive(now);
        if let Some(title) = window_title {
            let parts: Vec<String> = title
                .split(" — ").flat_map(|p| p.split(" – ")).flat_map(|p| p.split(" - "))
                .map(|p| p.trim().replace(" (Workspace)", ""))
                .collect();
            if let Some(s) = alive.iter().find(|s| s.project_name().is_some_and(|n| parts.contains(&n))) {
                return Some(*s);
            }
        }
        alive.first().copied()
    }
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
    fn limits_expire_when_they_reset() {
        let mut a = Account { session_percent: Some(80.0), resets_at: Some(UNIX_EPOCH + Duration::from_secs(10)), ..Default::default() };
        a.expire(UNIX_EPOCH + Duration::from_secs(20));
        assert_eq!(a.session_percent, Some(0.0));
    }
}
