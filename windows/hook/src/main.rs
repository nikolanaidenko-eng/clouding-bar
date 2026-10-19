//! cloudingbar-hook — the Claude Code hook command (see docs/protocol.md).
//!
//! Every hook event goes through here: the JSON Claude Code pipes in is
//! forwarded to the app (a named pipe on Windows), plus the Claude process
//! id, entrypoint and effort. Two events can be answered from the app, so
//! for them it waits for a reply and prints it as the hook's output:
//!   - PermissionRequest                (Allow / Always / Deny)
//!   - PreToolUse for AskUserQuestion   (pick an option or type an answer)
//!
//! The one rule: Claude must never get stuck because of us. Any trouble —
//! the app isn't running, doesn't answer, hangs, crashes, sends garbage —
//! ends in a silent exit 0 with no output: "no decision", and Claude
//! carries on as if this hook didn't exist (its own dialog shows).

use cloudingbar_core::protocol::{parse_reply, Reply, SOCKET_NAME};
use interprocess::local_socket::{prelude::*, GenericNamespaced, Stream};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// The app must confirm a request this fast.
const ACK: Duration = Duration::from_secs(2);
/// The longest a question / a permission is ever held.
const QUESTION_CAP: Duration = Duration::from_secs(300);
const PERMISSION_CAP: Duration = Duration::from_secs(900);

fn pass() -> ! {
    std::process::exit(0)
}

fn socket_name() -> String {
    // CLOUDINGBAR_SOCKET picks another name (tests, a second copy).
    std::env::var("CLOUDINGBAR_SOCKET").unwrap_or_else(|_| SOCKET_NAME.to_string())
}

/// `--statusline`: Claude Code's status line command. Hands the status JSON
/// (limits, context) to the app, then prints the line: the one you had
/// before (kept in ~/.cloudingbar/statusline-original), else the model and
/// the context fill.
fn status_line(input: &[u8]) -> ! {
    let name = socket_name();
    if let Ok(name) = name.as_str().to_ns_name::<GenericNamespaced>() {
        if let Ok(mut conn) = Stream::connect(name) {
            let _ = conn.write_all(input);
        }
    }
    let home = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).unwrap_or_default();
    let original = std::path::Path::new(&home).join(".cloudingbar").join("statusline-original");
    if let Ok(command) = std::fs::read_to_string(&original) {
        let command = command.trim();
        if !command.is_empty() {
            let mut shell = if cfg!(windows) {
                let mut c = std::process::Command::new("cmd");
                c.args(["/C", command]);
                c
            } else {
                let mut c = std::process::Command::new("/bin/sh");
                c.args(["-c", command]);
                c
            };
            if let Ok(mut child) = shell.stdin(std::process::Stdio::piped()).spawn() {
                if let Some(mut stdin) = child.stdin.take() { let _ = stdin.write_all(input); }
                let _ = child.wait();
                pass()
            }
        }
    }
    let v: Value = serde_json::from_slice(input).unwrap_or(Value::Null);
    let mut line = v.pointer("/model/display_name").and_then(Value::as_str).unwrap_or("Claude").to_string();
    if let Some(p) = v.pointer("/context_window/used_percentage").and_then(Value::as_f64) {
        line += &format!(" · context {}%", p.round());
    }
    println!("{line}");
    pass()
}

fn main() {
    let started = Instant::now();
    // Last resort if something below blocks in a way nobody foresaw.
    std::thread::spawn(|| {
        std::thread::sleep(PERMISSION_CAP + Duration::from_secs(30));
        std::process::exit(0);
    });

    let mut input = Vec::new();
    if std::io::stdin().read_to_end(&mut input).is_err() { pass() }
    if std::env::args().nth(1).as_deref() == Some("--statusline") { status_line(&input) }
    let Ok(Value::Object(mut event)) = serde_json::from_slice::<Value>(&input) else { pass() };

    for (env, key) in [("CLAUDE_CODE_ENTRYPOINT", "claude_entrypoint"), ("CLAUDE_EFFORT", "claude_effort")] {
        if let Ok(v) = std::env::var(env) { event.insert(key.into(), Value::String(v)); }
    }
    if let Some(pid) = std::env::var("CLAUDE_PID").ok().and_then(|p| p.parse::<u64>().ok()) {
        event.insert("claude_pid".into(), Value::from(pid));
    }

    let name = event.get("hook_event_name").and_then(Value::as_str).unwrap_or("");
    let is_permission = name == "PermissionRequest";
    let is_question = name == "PreToolUse" && event.get("tool_name").and_then(Value::as_str) == Some("AskUserQuestion");
    let cap = if is_permission { PERMISSION_CAP } else { QUESTION_CAP };

    // Compact JSON never contains a raw newline: one line, one message.
    let Ok(mut line) = serde_json::to_string(&Value::Object(event)) else { pass() };
    line.push('\n');

    let name = socket_name();
    let Ok(socket) = name.as_str().to_ns_name::<GenericNamespaced>() else { pass() };
    let Ok(mut conn) = Stream::connect(socket) else { pass() }; // the app isn't running
    if conn.write_all(line.as_bytes()).is_err() { pass() }
    if !(is_permission || is_question) { pass() }

    // Replies arrive on a thread, so waiting for them can time out.
    let (tx, rx) = mpsc::channel::<Option<Reply>>();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(conn);
        let mut buf = String::new();
        loop {
            buf.clear();
            match reader.read_line(&mut buf) {
                Ok(0) | Err(_) => { let _ = tx.send(None); return; } // closed: the app quit or crashed
                Ok(_) => { if tx.send(parse_reply(&buf)).is_err() { return; } }
            }
        }
    });

    let mut deadline = Instant::now() + ACK;
    loop {
        let wait = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(wait) {
            Ok(Some(Reply::Hold(seconds))) => {
                deadline = (Instant::now() + Duration::from_secs(seconds)).min(started + cap);
            }
            Ok(Some(Reply::Output(out))) => {
                let mut stdout = std::io::stdout();
                let _ = writeln!(stdout, "{out}");
                let _ = stdout.flush();
                pass()
            }
            // Pass, garbage, the connection gone, or out of time: no decision.
            _ => pass(),
        }
    }
}
