//! The wire format between Claude Code's hooks and the app (docs/protocol.md).
//!
//! One connection carries one message: a JSON object on one line. Hook
//! events are Claude Code's own JSON plus `claude_pid`, `claude_entrypoint`
//! and `claude_effort`; status messages (the status line, the VS Code tap)
//! carry `rate_limits` and/or `context_window` instead. For a permission or
//! a question the hook keeps the connection open and the app answers with
//! lines of its own: `{"hold": N}`, then `{"output": …}` or `{"pass": true}`.

use serde_json::{json, Map, Value};

/// The local socket's name: a named pipe on Windows (`\\.\pipe\cloudingbar`),
/// a socket file elsewhere.
pub const SOCKET_NAME: &str = "cloudingbar";

/// One message that arrived on the socket.
#[derive(Clone, Debug)]
pub struct Inbound(pub Map<String, Value>);

impl Inbound {
    pub fn parse(line: &[u8]) -> Option<Self> {
        match serde_json::from_slice::<Value>(line) {
            Ok(Value::Object(map)) => Some(Inbound(map)),
            _ => None,
        }
    }

    fn str(&self, key: &str) -> Option<&str> {
        self.0.get(key).and_then(Value::as_str)
    }

    pub fn event(&self) -> Option<&str> { self.str("hook_event_name") }
    pub fn session_id(&self) -> Option<&str> { self.str("session_id") }
    pub fn cwd(&self) -> Option<&str> { self.str("cwd") }
    pub fn transcript_path(&self) -> Option<&str> { self.str("transcript_path") }
    pub fn tool_name(&self) -> Option<&str> { self.str("tool_name") }
    pub fn entrypoint(&self) -> Option<&str> { self.str("claude_entrypoint") }
    pub fn effort(&self) -> Option<&str> { self.str("claude_effort") }
    pub fn notification_type(&self) -> Option<&str> { self.str("notification_type") }
    pub fn message(&self) -> Option<&str> { self.str("message") }
    pub fn agent_id(&self) -> Option<&str> { self.str("agent_id") }

    pub fn tool_input(&self) -> Map<String, Value> {
        self.0.get("tool_input").and_then(Value::as_object).cloned().unwrap_or_default()
    }

    pub fn permission_suggestions(&self) -> Option<Vec<Value>> {
        self.0.get("permission_suggestions").and_then(Value::as_array).cloned()
    }

    pub fn claude_pid(&self) -> Option<u32> {
        self.0.get("claude_pid").and_then(Value::as_u64).map(|p| p as u32)
    }

    /// A message the sender waits on for an answer.
    pub fn is_request(&self) -> bool {
        self.event() == Some("PermissionRequest")
            || (self.event() == Some("PreToolUse") && self.tool_name() == Some("AskUserQuestion"))
    }

    /// `rate_limits.<window>`: (used %, resets at in unix seconds).
    fn window(&self, name: &str) -> Option<(Option<f64>, Option<f64>)> {
        let w = self.0.get("rate_limits")?.get(name)?.as_object()?;
        Some((w.get("used_percentage").and_then(Value::as_f64), w.get("resets_at").and_then(Value::as_f64)))
    }

    /// The 5-hour limit.
    pub fn five_hour(&self) -> Option<(Option<f64>, Option<f64>)> { self.window("five_hour") }
    /// The weekly limit, on Pro and Max plans.
    pub fn seven_day(&self) -> Option<(Option<f64>, Option<f64>)> { self.window("seven_day") }

    pub fn context_used_percent(&self) -> Option<f64> {
        self.0.get("context_window")?.get("used_percentage")?.as_f64()
    }

    pub fn context_window_size(&self) -> Option<u64> {
        self.0.get("context_window")?.get("context_window_size")?.as_u64()
    }

    pub fn model_id(&self) -> Option<&str> {
        self.0.get("model")?.get("id")?.as_str()
    }
}

/// "Keep waiting up to `seconds` more."
pub fn hold(seconds: u64) -> String { format!("{}\n", json!({ "hold": seconds })) }
/// The final answer, printed by the hook as its output for Claude.
pub fn output(value: &Value) -> String { format!("{}\n", json!({ "output": value })) }
/// No decision: Claude's own UI takes it.
pub fn pass() -> String { "{\"pass\":true}\n".to_string() }

/// What the hook does with one reply line.
#[derive(Debug, PartialEq)]
pub enum Reply {
    Hold(u64),
    Output(Value),
    Pass,
}

pub fn parse_reply(line: &str) -> Option<Reply> {
    let v: Value = serde_json::from_str(line.trim()).ok()?;
    if let Some(n) = v.get("hold").and_then(Value::as_u64) {
        return Some(Reply::Hold(n));
    }
    if let Some(o) = v.get("output") {
        return Some(Reply::Output(o.clone()));
    }
    if v.get("pass").is_some() {
        return Some(Reply::Pass);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_status_line() {
        let m = Inbound::parse(br#"{"session_id":"s","rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1790000000},"seven_day":{"used_percentage":23}},"context_window":{"used_percentage":31,"context_window_size":1000000},"model":{"id":"claude-opus-5-5[1m]"}}"#).unwrap();
        assert_eq!(m.five_hour(), Some((Some(42.5), Some(1790000000.0))));
        assert_eq!(m.seven_day(), Some((Some(23.0), None)));
        assert_eq!(m.context_used_percent(), Some(31.0));
        assert_eq!(m.context_window_size(), Some(1_000_000));
        assert_eq!(m.model_id(), Some("claude-opus-5-5[1m]"));
        assert!(!m.is_request());
    }

    #[test]
    fn knows_what_waits_for_an_answer() {
        let p = Inbound::parse(br#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#).unwrap();
        let q = Inbound::parse(br#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}"#).unwrap();
        let t = Inbound::parse(br#"{"hook_event_name":"PreToolUse","tool_name":"Read"}"#).unwrap();
        assert!(p.is_request() && q.is_request() && !t.is_request());
    }

    #[test]
    fn replies_round_trip() {
        assert_eq!(parse_reply(&hold(15)), Some(Reply::Hold(15)));
        assert_eq!(parse_reply(&pass()), Some(Reply::Pass));
        assert_eq!(parse_reply(&output(&json!({"a": 1}))), Some(Reply::Output(json!({"a": 1}))));
        assert_eq!(parse_reply("nonsense"), None);
    }
}
