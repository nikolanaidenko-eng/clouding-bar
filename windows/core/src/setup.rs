//! Connects Clouding Bar to Claude Code: its hook for every event it listens
//! to, and its status line, merged into Claude Code's settings.json — never
//! replacing what's there, the file backed up first, an existing status line
//! kept to be called through ours. Key order is kept (serde_json's
//! preserve_order), so the file reads as before.

use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

pub const EVENTS: [&str; 11] = [
    "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification", "PreToolUse",
    "PostToolUse", "PostToolUseFailure", "PermissionRequest", "SubagentStart", "SubagentStop",
];

/// Seconds Claude Code gives the hook before cancelling it; the hook gives
/// up on its own well before.
fn timeout(event: &str) -> Option<u64> {
    match event {
        "PermissionRequest" => Some(960),
        "PreToolUse" => Some(330),
        _ => None,
    }
}

#[derive(Debug)]
pub enum SetupError {
    /// settings.json isn't plain JSON (comments?): left alone.
    Unreadable,
    Io(std::io::Error),
}

impl From<std::io::Error> for SetupError {
    fn from(e: std::io::Error) -> Self { SetupError::Io(e) }
}

fn read(path: &Path) -> Result<Option<Map<String, Value>>, SetupError> {
    match fs::read_to_string(path) {
        Ok(text) if text.trim().is_empty() => Ok(Some(Map::new())),
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Ok(Value::Object(m)) => Ok(Some(m)),
            _ => Err(SetupError::Unreadable),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// A command without its quotes: the old form of our hook (a path quoted
/// only when it had spaces) and the new one (always quoted) compare equal.
fn bare(cmd: &str) -> String { cmd.replace('"', "") }

fn same_command(a: &str, b: &str) -> bool { bare(a) == bare(b) }

/// Our hook is in for every event.
pub fn is_connected(settings: &Path, hook: &str) -> bool {
    let Ok(Some(s)) = read(settings) else { return false };
    let Some(hooks) = s.get("hooks").and_then(Value::as_object) else { return false };
    EVENTS.iter().all(|e| {
        hooks.get(*e).and_then(Value::as_array).into_iter().flatten().any(|entry| {
            entry.get("hooks").and_then(Value::as_array).into_iter().flatten()
                .any(|h| h.get("command").and_then(Value::as_str).is_some_and(|c| same_command(c, hook)))
        })
    })
}

/// Adds our hooks and status line. `original` gets the status line that
/// was there (ours calls it after itself). Returns the backup's path.
pub fn connect(settings: &Path, hook: &str, status_line: &str, original: &Path, backups: &Path)
    -> Result<Option<PathBuf>, SetupError>
{
    let before = read(settings)?;
    let mut s = before.clone().unwrap_or_default();

    let mut hooks = s.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
    for event in EVENTS {
        let mut entries = hooks.get(event).and_then(Value::as_array).cloned().unwrap_or_default();
        let mut found = false;
        for entry in entries.iter_mut() {
            let Some(list) = entry.get_mut("hooks").and_then(Value::as_array_mut) else { continue };
            for h in list.iter_mut() {
                if h.get("command").and_then(Value::as_str).is_some_and(|c| same_command(c, hook)) {
                    h["command"] = json!(hook); // the old unquoted form becomes the new one
                    if let Some(t) = timeout(event) { h["timeout"] = json!(t); }
                    found = true;
                }
            }
        }
        if !found {
            let mut h = json!({ "type": "command", "command": hook });
            if let Some(t) = timeout(event) { h["timeout"] = json!(t); }
            entries.push(json!({ "hooks": [h] }));
        }
        hooks.insert(event.to_string(), Value::Array(entries));
    }
    s.insert("hooks".into(), Value::Object(hooks));

    let mut line = s.get("statusLine").and_then(Value::as_object).cloned().unwrap_or_default();
    if let Some(current) = line.get("command").and_then(Value::as_str) {
        if !same_command(current, status_line) {
            fs::write(original, current)?;
        }
    }
    line.insert("type".into(), json!("command"));
    line.insert("command".into(), json!(status_line));
    line.insert("refreshInterval".into(), json!(5));
    s.insert("statusLine".into(), Value::Object(line));

    if before.as_ref() == Some(&s) {
        return Ok(None);
    }
    let mut backup = None;
    if let Ok(old) = fs::read(settings) {
        fs::create_dir_all(backups)?;
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs();
        let path = backups.join(format!("settings-{stamp}.json"));
        fs::write(&path, old)?;
        backup = Some(path);
    }
    // A symlinked settings.json: the file it points to is the one replaced,
    // the link stays.
    let target = fs::canonicalize(settings).unwrap_or_else(|_| settings.to_path_buf());
    if let Some(dir) = target.parent() { fs::create_dir_all(dir)?; }
    let tmp = target.with_extension("json.cloudingbar-new");
    fs::write(&tmp, serde_json::to_string_pretty(&Value::Object(s)).unwrap() + "\n")?;
    fs::rename(&tmp, &target)?;
    Ok(backup)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merges_and_keeps_what_was_there() {
        let dir = std::env::temp_dir().join(format!("cb-setup-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let settings = dir.join("settings.json");
        fs::write(&settings, r#"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other.exe"}]}]}, "statusLine": {"type": "command", "command": "mine.ps1"}}"#).unwrap();
        let hook = "C:\\cb\\cloudingbar-hook.exe";
        assert!(!is_connected(&settings, hook));
        let backup = connect(&settings, hook, "C:\\cb\\statusline.cmd", &dir.join("statusline-original"), &dir.join("backups")).unwrap();
        assert!(backup.is_some());
        assert!(is_connected(&settings, hook));
        let v: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert_eq!(v.as_object().unwrap().keys().next().unwrap(), "model", "key order kept");
        let stop: Vec<&str> = v["hooks"]["Stop"].as_array().unwrap().iter()
            .flat_map(|e| e["hooks"].as_array().unwrap()).map(|h| h["command"].as_str().unwrap()).collect();
        assert_eq!(stop, vec!["other.exe", hook]);
        assert_eq!(v["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"], 960);
        assert_eq!(fs::read_to_string(dir.join("statusline-original")).unwrap(), "mine.ps1");
        // Again: nothing changes, no second backup.
        assert!(connect(&settings, hook, "C:\\cb\\statusline.cmd", &dir.join("statusline-original"), &dir.join("backups")).unwrap().is_none());
        // Not plain JSON: left alone.
        fs::write(&settings, "{ // comment\n}").unwrap();
        assert!(matches!(connect(&settings, hook, "x", &dir.join("o"), &dir.join("b")), Err(SetupError::Unreadable)));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn old_unquoted_hook_is_migrated_not_duplicated() {
        let dir = std::env::temp_dir().join(format!("cb-migrate-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let settings = dir.join("settings.json");
        let (old, new) = ("C:/cb/cloudingbar-hook.exe", "\"C:/cb/cloudingbar-hook.exe\"");
        let (old_sl, new_sl) = (format!("{old} --statusline"), format!("{new} --statusline"));
        connect(&settings, old, &old_sl, &dir.join("orig"), &dir.join("backups")).unwrap();
        assert!(is_connected(&settings, old) && is_connected(&settings, new));
        // Connect with the new form: the old entries are rewritten in place.
        connect(&settings, new, &new_sl, &dir.join("orig"), &dir.join("backups")).unwrap();
        let v: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        for e in EVENTS {
            let cmds: Vec<&str> = v["hooks"][e].as_array().unwrap().iter()
                .flat_map(|x| x["hooks"].as_array().unwrap()).map(|h| h["command"].as_str().unwrap()).collect();
            assert_eq!(cmds, vec![new], "{e}");
        }
        assert_eq!(v["statusLine"]["command"], new_sl.as_str());
        assert!(!dir.join("orig").exists(), "our own old status line isn't kept as the original");
        assert!(connect(&settings, new, &new_sl, &dir.join("orig"), &dir.join("backups")).unwrap().is_none());
        let _ = fs::remove_dir_all(&dir);
    }
}
