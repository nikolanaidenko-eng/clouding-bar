//! The session's transcript (the JSONL file Claude Code writes): the context
//! fill at the latest reply, and the model. Only the end of the file is read.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

pub struct Latest {
    /// Input + cache reads + cache writes of the latest reply.
    pub context_tokens: Option<u64>,
    pub model: Option<String>,
    /// The chat's title: the one you gave it, else Claude Code's.
    pub title: Option<String>,
}

/// The context window: 1M for "[1m]" models (or once past 200k), else 200k.
pub fn window_for(model: Option<&str>, tokens: u64) -> u64 {
    if model.is_some_and(|m| m.contains("[1m]")) || tokens > 200_000 { 1_000_000 } else { 200_000 }
}

/// The latest reply and the title in the last 512 KB of the transcript.
pub fn latest(path: &str) -> Option<Latest> {
    let mut f = File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let start = len.saturating_sub(512 * 1024);
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    latest_in(&buf)
}

fn has(line: &[u8], mark: &[u8]) -> bool { line.windows(mark.len()).any(|w| w == mark) }

/// The newest reply by its time — Claude Code writes some old replies again
/// later, with their old time, and those say nothing about the context now.
pub fn latest_in(bytes: &[u8]) -> Option<Latest> {
    const ASSISTANT: &[u8] = br#""type":"assistant""#;
    const AI_TITLE: &[u8] = br#""type":"ai-title""#;
    const CUSTOM_TITLE: &[u8] = br#""type":"custom-title""#;
    let mut best: Option<(String, u64, Option<String>)> = None;
    let (mut ai, mut custom) = (None, None);
    for line in bytes.split(|b| *b == b'\n') {
        if has(line, AI_TITLE) || has(line, CUSTOM_TITLE) {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(line) {
                if let Some(t) = v.get("customTitle").and_then(|x| x.as_str()).filter(|t| !t.is_empty()) { custom = Some(t.to_string()); }
                if let Some(t) = v.get("aiTitle").and_then(|x| x.as_str()).filter(|t| !t.is_empty()) { ai = Some(t.to_string()); }
            }
            continue;
        }
        if !has(line, ASSISTANT) { continue; }
        let Ok(v) = serde_json::from_slice::<serde_json::Value>(line) else { continue };
        if v.get("isSidechain").and_then(|x| x.as_bool()) == Some(true) { continue; }
        let Some(msg) = v.get("message") else { continue };
        let model = msg.get("model").and_then(|m| m.as_str());
        if model == Some("<synthetic>") { continue; }
        let Some(u) = msg.get("usage") else { continue };
        let n = |k: &str| u.get(k).and_then(|x| x.as_u64()).unwrap_or(0);
        let tokens = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens");
        let requested = v.get("requestedModel").and_then(|x| x.as_str());
        let time = v.get("timestamp").and_then(|x| x.as_str()).unwrap_or("").to_string();
        if best.as_ref().map_or(true, |b| time >= b.0) {
            best = Some((time, tokens, requested.or(model).map(str::to_string)));
        }
    }
    let title = custom.or(ai);
    if best.is_none() && title.is_none() { return None; }
    Some(Latest { context_tokens: best.as_ref().map(|b| b.1), model: best.and_then(|b| b.2), title })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_latest_reply() {
        let t = br#"{"type":"user","message":{"content":"hi"}}
{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":90000,"cache_creation_input_tokens":100}}}
{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-5-5","usage":{"input_tokens":5}}}
"#;
        let l = latest_in(t).unwrap();
        assert_eq!(l.context_tokens, Some(90_110));
        assert_eq!(l.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(window_for(Some("claude-opus-5-5[1m]"), 10), 1_000_000);
        assert_eq!(window_for(None, 10), 200_000);
    }

    #[test]
    fn an_old_reply_written_again_and_the_title() {
        let t = br#"{"type":"assistant","timestamp":"2026-10-19T10:00:00.000Z","message":{"model":"m","usage":{"input_tokens":1000}}}
{"type":"assistant","timestamp":"2026-10-19T12:00:00.000Z","message":{"model":"m","usage":{"input_tokens":5000}}}
{"type":"ai-title","aiTitle":"Status bar","sessionId":"x"}
{"type":"assistant","timestamp":"2026-10-19T10:00:00.000Z","message":{"model":"m","usage":{"input_tokens":1000}}}
"#;
        let l = latest_in(t).unwrap();
        assert_eq!(l.context_tokens, Some(5000), "the newest reply, not the last line");
        assert_eq!(l.title.as_deref(), Some("Status bar"));
        let renamed = br#"{"type":"ai-title","aiTitle":"Status bar"}
{"type":"custom-title","customTitle":"My bar"}
"#;
        assert_eq!(latest_in(renamed).unwrap().title.as_deref(), Some("My bar"));
    }
}
