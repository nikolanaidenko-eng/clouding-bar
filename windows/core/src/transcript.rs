//! The session's transcript (the JSONL file Claude Code writes): the context
//! fill at the latest reply, and the model. Only the end of the file is read.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

pub struct Latest {
    /// Input + cache reads + cache writes of the latest reply.
    pub context_tokens: u64,
    pub model: Option<String>,
}

/// The context window: 1M for "[1m]" models (or once past 200k), else 200k.
pub fn window_for(model: Option<&str>, tokens: u64) -> u64 {
    if model.is_some_and(|m| m.contains("[1m]")) || tokens > 200_000 { 1_000_000 } else { 200_000 }
}

/// The latest reply in the last 512 KB of the transcript.
pub fn latest(path: &str) -> Option<Latest> {
    let mut f = File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let start = len.saturating_sub(512 * 1024);
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    latest_in(&buf)
}

pub fn latest_in(bytes: &[u8]) -> Option<Latest> {
    for line in bytes.split(|b| *b == b'\n').rev() {
        const MARK: &[u8] = br#""type":"assistant""#;
        if !line.windows(MARK.len()).any(|w| w == MARK) {
            continue;
        }
        let Ok(v) = serde_json::from_slice::<serde_json::Value>(line) else { continue };
        if v.get("isSidechain").and_then(|x| x.as_bool()) == Some(true) {
            continue;
        }
        let msg = v.get("message")?;
        let model = msg.get("model").and_then(|m| m.as_str());
        if model == Some("<synthetic>") {
            continue;
        }
        let Some(u) = msg.get("usage") else { continue };
        let n = |k: &str| u.get(k).and_then(|x| x.as_u64()).unwrap_or(0);
        let tokens = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens");
        let requested = v.get("requestedModel").and_then(|x| x.as_str());
        return Some(Latest { context_tokens: tokens, model: requested.or(model).map(str::to_string) });
    }
    None
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
        assert_eq!(l.context_tokens, 90_110);
        assert_eq!(l.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(window_for(Some("claude-opus-5-5[1m]"), 10), 1_000_000);
        assert_eq!(window_for(None, 10), 200_000);
    }
}
