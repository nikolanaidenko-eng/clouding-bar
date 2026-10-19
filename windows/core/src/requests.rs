//! Something Claude waits on that the app can answer: a permission, or
//! questions (AskUserQuestion). The outputs follow Claude Code's hooks
//! (code.claude.com/docs/en/hooks), the same as the macOS app's.

use crate::protocol::Inbound;
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;

#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Permission,
    Question,
}

#[derive(Clone, Debug)]
pub struct Question {
    pub text: String,
    pub options: Vec<String>,
    pub descriptions: Vec<String>,
    pub multi_select: bool,
}

#[derive(Clone, Debug)]
pub struct Request {
    pub kind: Kind,
    /// Came from PermissionRequest (else PreToolUse).
    pub via_permission: bool,
    pub session_id: Option<String>,
    pub entrypoint: Option<String>,
    pub tool_name: String,
    pub tool_input: Map<String, Value>,
    pub suggestions: Option<Vec<Value>>,
    pub questions: Vec<Question>,
    pub index: usize,
    pub answers: Map<String, Value>,
    pub picked: BTreeSet<usize>,
}

impl Request {
    pub fn new(m: &Inbound) -> Option<Self> {
        let tool_name = m.tool_name().unwrap_or("tool").to_string();
        let tool_input = m.tool_input();
        let mut questions = Vec::new();
        let kind = if tool_name == "AskUserQuestion" {
            for q in tool_input.get("questions").and_then(Value::as_array).into_iter().flatten() {
                let Some(text) = q.get("question").and_then(Value::as_str) else { continue };
                let opts: Vec<&Value> = q.get("options").and_then(Value::as_array).into_iter().flatten()
                    .filter(|o| o.get("label").and_then(Value::as_str).is_some())
                    .collect();
                questions.push(Question {
                    text: text.to_string(),
                    options: opts.iter().map(|o| o["label"].as_str().unwrap().to_string()).collect(),
                    descriptions: opts.iter()
                        .map(|o| o.get("description").and_then(Value::as_str).unwrap_or("").to_string())
                        .collect(),
                    multi_select: q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
                });
            }
            if questions.is_empty() {
                return None;
            }
            Kind::Question
        } else {
            Kind::Permission
        };
        Some(Request {
            kind,
            via_permission: m.event() == Some("PermissionRequest"),
            session_id: m.session_id().map(str::to_string),
            entrypoint: m.entrypoint().map(str::to_string),
            tool_name,
            tool_input,
            suggestions: m.permission_suggestions(),
            questions,
            index: 0,
            answers: Map::new(),
            picked: BTreeSet::new(),
        })
    }

    pub fn current(&self) -> Option<&Question> { self.questions.get(self.index) }

    /// VS Code and the desktop app show their own dialog alongside the hook
    /// and take whichever answer comes first, so holding there costs
    /// nothing. Elsewhere (terminal, scripts) Claude may wait on the hook.
    pub fn host_answers_in_parallel(&self) -> bool {
        matches!(self.entrypoint.as_deref(), Some("claude-vscode") | Some("claude-desktop"))
    }

    /// Records an answer to the current question. True when all are done.
    pub fn answer_current(&mut self, answer: &str) -> bool {
        if let Some(q) = self.current() {
            let key = q.text.clone();
            self.answers.insert(key, Value::String(answer.to_string()));
            self.index += 1;
            self.picked.clear();
        }
        self.index >= self.questions.len()
    }

    /// ("Run", "npm test"), ("Edit", "Makefile"), …
    pub fn summary(&self) -> (String, String) {
        let s = |k: &str| self.tool_input.get(k).and_then(Value::as_str).map(str::to_string);
        let file = |k: &str| s(k).map(|p| p.rsplit(['/', '\\']).next().unwrap_or("").to_string());
        let one_line = |t: String| t.replace('\n', " ⏎ ");
        match self.tool_name.as_str() {
            "Bash" | "PowerShell" => ("Run".into(), one_line(s("command").unwrap_or_default())),
            "Edit" | "MultiEdit" => ("Edit".into(), file("file_path").unwrap_or_default()),
            "Write" => ("Write".into(), file("file_path").unwrap_or_default()),
            "NotebookEdit" => ("Edit".into(), file("notebook_path").unwrap_or_default()),
            "WebFetch" => ("Fetch".into(), s("url").unwrap_or_default()),
            "WebSearch" => ("Search".into(), s("query").unwrap_or_default()),
            name if name.starts_with("mcp__") => {
                ("Use".into(), name.split("__").skip(1).collect::<Vec<_>>().join(" · "))
            }
            name => (
                name.to_string(),
                self.tool_input.values().find_map(Value::as_str).map(|t| one_line(t.to_string())).unwrap_or_default(),
            ),
        }
    }

    fn permission_output(decision: Value) -> Value {
        json!({ "hookSpecificOutput": { "hookEventName": "PermissionRequest", "decision": decision } })
    }

    pub fn allow() -> Value { Self::permission_output(json!({ "behavior": "allow" })) }

    /// Allow, and remember it the way Claude itself suggested. Without a
    /// suggestion it's a plain allow.
    pub fn always(&self) -> Value {
        match &self.suggestions {
            Some(s) if !s.is_empty() => {
                Self::permission_output(json!({ "behavior": "allow", "updatedPermissions": s }))
            }
            _ => Self::allow(),
        }
    }

    pub fn deny() -> Value {
        Self::permission_output(json!({ "behavior": "deny", "message": "Denied from Clouding Bar." }))
    }

    /// The questions with the answers filled in.
    pub fn answer_output(&self) -> Value {
        let mut input = self.tool_input.clone();
        input.insert("answers".into(), Value::Object(self.answers.clone()));
        if self.via_permission {
            Self::permission_output(json!({ "behavior": "allow", "updatedInput": input }))
        } else {
            json!({ "hookSpecificOutput": {
                "hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input } })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inbound(s: &str) -> Inbound { Inbound::parse(s.as_bytes()).unwrap() }

    #[test]
    fn a_permission_and_its_outputs() {
        let r = Request::new(&inbound(r#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test\nnpm run build"},"permission_suggestions":[{"type":"addRules"}]}"#)).unwrap();
        assert_eq!(r.kind, Kind::Permission);
        assert_eq!(r.summary(), ("Run".to_string(), "npm test ⏎ npm run build".to_string()));
        assert_eq!(Request::allow()["hookSpecificOutput"]["decision"]["behavior"], "allow");
        assert_eq!(r.always()["hookSpecificOutput"]["decision"]["updatedPermissions"][0]["type"], "addRules");
        assert_eq!(Request::deny()["hookSpecificOutput"]["decision"]["behavior"], "deny");
    }

    #[test]
    fn questions_answered_one_by_one() {
        let mut r = Request::new(&inbound(r#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","claude_entrypoint":"claude-vscode","tool_input":{"questions":[{"question":"Colour?","options":[{"label":"Blue","description":"calm"},{"label":"Red"}]},{"question":"Size?","options":[{"label":"S"}],"multiSelect":true}]}}"#)).unwrap();
        assert_eq!(r.kind, Kind::Question);
        assert!(r.host_answers_in_parallel());
        assert_eq!(r.current().unwrap().descriptions, vec!["calm".to_string(), "".to_string()]);
        assert!(!r.answer_current("Blue"));
        assert!(r.current().unwrap().multi_select);
        assert!(r.answer_current("S"));
        let out = r.answer_output();
        assert_eq!(out["hookSpecificOutput"]["decision"]["updatedInput"]["answers"]["Colour?"], "Blue");
    }

    #[test]
    fn a_question_via_pre_tool_use() {
        let mut r = Request::new(&inbound(r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Go?","options":[{"label":"Yes"}]}]}}"#)).unwrap();
        r.answer_current("Yes");
        let out = r.answer_output();
        assert_eq!(out["hookSpecificOutput"]["permissionDecision"], "allow");
        assert_eq!(out["hookSpecificOutput"]["updatedInput"]["answers"]["Go?"], "Yes");
    }

    #[test]
    fn no_questions_no_request() {
        assert!(Request::new(&inbound(r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}"#)).is_none());
    }
}
