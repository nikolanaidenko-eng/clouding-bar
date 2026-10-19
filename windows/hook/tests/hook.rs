//! The hook against a stand-in app: no app, an answer, an app that hangs.

use interprocess::local_socket::{prelude::*, GenericNamespaced, ListenerOptions};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const PERMISSION: &str = r#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}"#;

fn run(socket: &str, input: &str) -> (String, Duration) {
    let started = Instant::now();
    let mut child = Command::new(env!("CARGO_BIN_EXE_cloudingbar-hook"))
        .env("CLOUDINGBAR_SOCKET", socket)
        .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "the hook always exits 0");
    (String::from_utf8(out.stdout).unwrap(), started.elapsed())
}

#[test]
fn never_keeps_claude_waiting_and_passes_answers_on() {
    let name = format!("cb-test-{}.sock", std::process::id());

    // 1. No app: no output, at once.
    let (out, took) = run(&name, PERMISSION);
    assert!(out.is_empty() && took < Duration::from_secs(1), "no app: {out:?} in {took:?}");

    let listener = ListenerOptions::new().name(name.as_str().to_ns_name::<GenericNamespaced>().unwrap())
        .create_sync().unwrap();

    // 2. The app holds it, then answers Allow.
    let server = std::thread::spawn(move || {
        let conn = listener.accept().unwrap();
        let mut reader = BufReader::new(conn);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        assert!(line.contains("PermissionRequest"));
        let conn = reader.get_mut();
        conn.write_all(b"{\"hold\":30}\n").unwrap();
        std::thread::sleep(Duration::from_millis(300));
        conn.write_all(b"{\"output\":{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}}\n").unwrap();
        // 3. Then an app that never answers.
        let conn = listener.accept().unwrap();
        std::thread::sleep(Duration::from_secs(4));
        drop(conn);
    });
    let (out, _) = run(&name, PERMISSION);
    assert!(out.contains(r#""behavior":"allow""#), "answer passed on: {out:?}");

    let (out, took) = run(&name, PERMISSION);
    assert!(out.is_empty(), "a silent app: no decision");
    assert!(took >= Duration::from_millis(1900) && took < Duration::from_secs(3), "gave up after ~2 s: {took:?}");
    server.join().unwrap();
}
