//! The local socket (a named pipe on Windows) the hook and the status line
//! talk to: one message per connection; for a request the connection stays
//! open until it's answered or the hook goes away.

use crate::state::Shared;
use cloudingbar_core::protocol::{Inbound, SOCKET_NAME};
use interprocess::local_socket::{prelude::*, GenericNamespaced, ListenerOptions, Stream};
use std::io::{BufRead, BufReader, Read};
use std::time::SystemTime;
use tauri::AppHandle;

pub fn name() -> String {
    std::env::var("CLOUDINGBAR_SOCKET").unwrap_or_else(|_| SOCKET_NAME.to_string())
}

pub fn start(app: AppHandle, shared: Shared) {
    std::thread::spawn(move || {
        let name = name();
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
            let (app, shared) = (app.clone(), shared.clone());
            std::thread::spawn(move || handle(conn, app, shared));
        }
    });
}

fn handle(conn: Stream, app: AppHandle, shared: Shared) {
    let (recv, send) = conn.split();
    let mut reader = BufReader::new(recv);
    let mut line = Vec::new();
    // One line, or everything up to the sender closing (the status line).
    if reader.by_ref().take(4 << 20).read_until(b'\n', &mut line).is_err() { return; }
    let Some(m) = Inbound::parse(&line) else { return };
    let id = {
        let mut st = shared.lock();
        st.store.apply(&m, SystemTime::now());
        st.moved_on(&m);
        if m.is_request() { st.add(&m, send) } else { None }
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
