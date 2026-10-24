//! The local socket (a named pipe on Windows) the hook and the status line
//! talk to: one message per connection; for a request the connection stays
//! open until it's answered or the hook goes away.

use crate::state::Shared;
use cloudingbar_core::protocol::{self, socket_name, Inbound, SOCKET_NAME};
use interprocess::local_socket::{prelude::*, GenericNamespaced, ListenerOptions, Stream};
use std::io::{BufReader, ErrorKind, Read, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, SystemTime};
use tauri::AppHandle;

/// Most requests waiting for an answer at once, and how long a sender may
/// take to deliver its one line.
const MAX_PENDING: usize = 32;
const READ_TIMEOUT: Duration = Duration::from_secs(10);
/// Connections being served at once (each has a thread).
const MAX_CONNECTIONS: usize = 64;
static OPEN: AtomicUsize = AtomicUsize::new(0);

/// Listens on the user's pipe and, for a release or two, on the old shared
/// name too (hooks installed before the rename still talk to it).
pub fn start(app: AppHandle, shared: Shared) {
    let mut names = vec![socket_name()];
    if std::env::var("CLOUDINGBAR_SOCKET").is_err() && names[0] != SOCKET_NAME { names.push(SOCKET_NAME.to_string()); }
    for name in names {
        let (app, shared) = (app.clone(), shared.clone());
        std::thread::spawn(move || listen(name, app, shared));
    }
}

fn listen(name: String, app: AppHandle, shared: Shared) {
    let Ok(ns) = name.as_str().to_ns_name::<GenericNamespaced>() else { return };
    // A socket file left by a copy that didn't quit cleanly is taken over
    // (named pipes on Windows don't linger like that).
    let listener = match ListenerOptions::new().name(ns).try_overwrite(true).create_sync() {
        Ok(l) => l,
        Err(e) => {
            eprintln!("Clouding Bar: can't open the socket {name}: {e}");
            return;
        }
    };
    for conn in listener.incoming().flatten() {
        if OPEN.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            OPEN.fetch_sub(1, Ordering::SeqCst);
            continue; // too many at once: this one is dropped
        }
        let (app, shared) = (app.clone(), shared.clone());
        std::thread::spawn(move || {
            handle(conn, app, shared);
            OPEN.fetch_sub(1, Ordering::SeqCst);
        });
    }
}

fn handle(conn: Stream, app: AppHandle, shared: Shared) {
    // The one line has READ_TIMEOUT to arrive: polled without blocking, so a
    // sender that connects and says nothing can't hold the thread.
    if conn.set_nonblocking(true).is_err() { return; }
    let mut line = Vec::new();
    let deadline = std::time::Instant::now() + READ_TIMEOUT;
    let mut buf = [0u8; 4096];
    // One line, or everything up to the sender closing (the status line).
    loop {
        if std::time::Instant::now() >= deadline || line.len() > (4 << 20) { return; }
        match (&conn).read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                line.extend_from_slice(&buf[..n]);
                if line.contains(&b'\n') { break; }
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(20)),
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(_) => return,
        }
    }
    // Back to blocking for the wait that follows.
    if conn.set_nonblocking(false).is_err() { return; }
    let (recv, mut send) = conn.split();
    let mut reader = BufReader::new(recv);
    if let Some(i) = line.iter().position(|b| *b == b'\n') { line.truncate(i + 1); }
    let Some(m) = Inbound::parse(&line) else { return };
    let id = {
        let mut st = shared.lock();
        st.store.apply(&m, SystemTime::now());
        st.moved_on(&m);
        if !m.is_request() { None }
        else if st.pending.len() >= MAX_PENDING {
            let _ = send.write_all(protocol::pass().as_bytes()); // too many waiting: leave it to Claude's own dialog
            None
        } else { st.add(&m, send) }
    };
    crate::changed(&app, &shared);
    // A request: when the hook goes away (it gave up, or Claude's own dialog
    // got the answer), so does the card.
    if let Some(id) = id {
        let mut buf = [0u8; 256];
        while matches!(reader.read(&mut buf), Ok(n) if n > 0) {}
        let gone = shared.lock().pending.iter().any(|p| p.id == id);
        if gone {
            shared.lock().pending.retain(|p| p.id != id);
            crate::changed(&app, &shared);
        }
    }
}
