//! Clouding Bar for Windows: Claude Code at a glance in a floating pill at
//! the top of the screen, the full panel on hover, Claude's permission
//! requests and questions answered right there. A tray icon holds the menu.
//! The same protocol as the macOS app (docs/protocol.md), over a named pipe.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod front;
mod server;
mod state;

use cloudingbar_core::setup;
use state::{Shared, Snapshot};
use std::path::PathBuf;
use std::time::{Duration, SystemTime};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, WebviewWindow};

/// Tells the page the state changed.
pub fn changed(app: &AppHandle, shared: &Shared) {
    let snap = shared.lock().snapshot();
    let _ = app.emit("state", snap);
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).unwrap_or_default())
}

/// ~/.cloudingbar: the hook's stable home, backups, the old status line.
/// Built anywhere but Windows (developing on a Mac, where the macOS app
/// owns ~/.cloudingbar), everything goes to a folder of its own instead.
fn data_dir() -> PathBuf { home().join(if cfg!(windows) { ".cloudingbar" } else { ".cloudingbar-dev" }) }

/// How a path goes into a hook command: forward slashes (Claude Code runs
/// hooks through Git Bash on Windows), always quoted.
fn command_path(p: &std::path::Path) -> String {
    let s = p.to_string_lossy().replace('\\', "/");
    format!("\"{s}\"")
}

fn hook_exe() -> PathBuf { data_dir().join(if cfg!(windows) { "cloudingbar-hook.exe" } else { "cloudingbar-hook" }) }

fn hook_command() -> String { command_path(&hook_exe()) }

/// Claude Code's settings — on a development Mac a stand-in, never the real one.
fn settings_path() -> PathBuf {
    if cfg!(windows) { home().join(".claude").join("settings.json") } else { data_dir().join("claude-settings.json") }
}

/// The bundled hook, next to the app.
fn bundled_hook() -> Option<PathBuf> {
    std::env::current_exe().ok().map(|e| e.with_file_name(hook_exe().file_name().unwrap()))
}

/// Puts the bundled hook at its stable path (atomically: a temp file next to
/// it, then a rename). With `force` off, only an already installed hook that
/// differs from the bundled one is replaced, so an update of the app brings
/// its hook along (an old hook talks to an old pipe name). A hook in use
/// can't be replaced on Windows: that's retried at the next start.
fn install_hook(force: bool) -> Result<(), String> {
    let Some(bundled) = bundled_hook().filter(|b| b.exists()) else { return Ok(()) };
    let target = hook_exe();
    if !force {
        let (Ok(new), Ok(old)) = (std::fs::read(&bundled), std::fs::read(&target)) else { return Ok(()) };
        if new == old { return Ok(()); }
    }
    let tmp = target.with_extension("new");
    std::fs::copy(&bundled, &tmp).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &target).map_err(|e| { let _ = std::fs::remove_file(&tmp); e.to_string() })
}

/// Puts the hook next to the data (a stable path that survives updates of
/// the app) and registers it, and the status line, with Claude Code.
fn connect(shared: &Shared) -> Result<(), String> {
    std::fs::create_dir_all(data_dir()).map_err(|e| e.to_string())?;
    install_hook(true)?;
    setup::connect(&settings_path(), &hook_command(), &format!("{} --statusline", hook_command()),
                   &data_dir().join("statusline-original"), &data_dir().join("backups"))
        .map_err(|e| match e {
            setup::SetupError::Unreadable =>
                "~/.claude/settings.json isn't plain JSON, so it was left alone. Add the hooks by hand (see the README).".to_string(),
            setup::SetupError::Io(e) => e.to_string(),
        })?;
    shared.lock().hooks_connected = true;
    Ok(())
}

// MARK: Commands for the page

#[tauri::command]
fn snapshot(shared: tauri::State<'_, Shared>) -> Snapshot { shared.lock().snapshot() }

#[tauri::command]
fn answer(app: AppHandle, shared: tauri::State<'_, Shared>, id: u64, action: String, index: Option<usize>, text: Option<String>) {
    shared.lock().answer(id, &action, index, text);
    changed(&app, &shared);
}

#[tauri::command]
fn touch(shared: tauri::State<'_, Shared>, id: u64) { shared.lock().touch(id); }

/// A chat picked in the widget: follow it, and bring its conversation up
/// (the Claude extension opens one by its id).
#[tauri::command]
fn focus_session(app: AppHandle, shared: tauri::State<'_, Shared>, id: String) {
    let vscode = {
        let mut st = shared.lock();
        st.pick(&id);
        st.store.sessions.get(&id).is_some_and(|s| s.entrypoint.as_deref() == Some("claude-vscode"))
    };
    changed(&app, &shared);
    // The id ends up in a URL handed to the shell: only plain ids pass.
    let plain = (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    if vscode && plain { open_url(&format!("vscode://anthropic.claude-code/open?session={id}")); }
}

fn open_url(url: &str) {
    if cfg!(windows) {
        let _ = std::process::Command::new("cmd").args(["/C", "start", "", url]).spawn();
    } else {
        let _ = std::process::Command::new("open").arg(url).spawn();
    }
}

/// CLOUDINGBAR_EXPAND: start with the panel open (for checking how it looks).
#[tauri::command]
fn start_expanded() -> bool { std::env::var("CLOUDINGBAR_EXPAND").is_ok() }

#[tauri::command]
fn connect_claude(app: AppHandle, shared: tauri::State<'_, Shared>) {
    let result = connect(&shared);
    shared.lock().setup_message = Some(match result {
        Ok(()) => "Connected. New Claude Code sessions report here.".into(),
        Err(e) => format!("Couldn't connect: {e}"),
    });
    changed(&app, &shared);
}

/// The page measured itself: the window follows, its top centre in place.
#[tauri::command]
fn resize(window: WebviewWindow, width: f64, height: f64) {
    let (Ok(pos), Ok(size), Ok(scale)) = (window.outer_position(), window.outer_size(), window.scale_factor()) else { return };
    let centre = (pos.x as f64 + size.width as f64 / 2.0) / scale;
    let _ = window.set_size(LogicalSize::new(width, height));
    let _ = window.set_position(LogicalPosition::new(centre - width / 2.0, pos.y as f64 / scale));
}

/// At the start: the top centre of the main screen.
fn place(window: &WebviewWindow) {
    let Ok(Some(monitor)) = window.primary_monitor() else { return };
    let scale = monitor.scale_factor();
    let width = monitor.size().width as f64 / scale;
    let left = monitor.position().x as f64 / scale;
    let top = monitor.position().y as f64 / scale;
    let w = window.outer_size().map(|s| s.width as f64 / scale).unwrap_or(260.0);
    let _ = window.set_position(LogicalPosition::new(left + (width - w) / 2.0, top + 8.0));
}

fn tray(app: &tauri::App, shared: Shared) -> tauri::Result<()> {
    let title = MenuItem::with_id(app, "title", "Clouding Bar", false, None::<&str>)?;
    let show = MenuItem::with_id(app, "show", "Show or Hide the Widget", true, None::<&str>)?;
    let connect_item = MenuItem::with_id(app, "connect", "Connect to Claude Code", true, None::<&str>)?;
    let folder = MenuItem::with_id(app, "folder", "Open the Data Folder", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Clouding Bar", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&title, &sep, &show, &connect_item, &folder, &sep, &quit])?;
    let mut builder = TrayIconBuilder::new().menu(&menu).tooltip("Clouding Bar");
    if let Some(icon) = app.default_window_icon() { builder = builder.icon(icon.clone()); }
    builder.on_menu_event(move |app, event| match event.id.as_ref() {
        "show" => {
            if let Some(w) = app.get_webview_window("widget") {
                if w.is_visible().unwrap_or(true) { let _ = w.hide(); } else { let _ = w.show(); }
            }
        }
        "connect" => {
            let result = connect(&shared);
            shared.lock().setup_message = Some(match result {
                Ok(()) => "Connected. New Claude Code sessions report here.".into(),
                Err(e) => format!("Couldn't connect: {e}"),
            });
            changed(app, &shared);
        }
        "folder" => {
            let dir = data_dir();
            let _ = std::fs::create_dir_all(&dir);
            let opener = if cfg!(windows) { "explorer" } else { "open" };
            let _ = std::process::Command::new(opener).arg(dir).spawn();
        }
        "quit" => app.exit(0),
        _ => {}
    })
    .build(app)?;
    Ok(())
}

fn main() {
    let shared = Shared::default();
    let _ = install_hook(false);
    shared.lock().hooks_connected = setup::is_connected(&settings_path(), &hook_command());
    let ticking = shared.clone();
    tauri::Builder::default()
        .manage(shared.clone())
        .invoke_handler(tauri::generate_handler![snapshot, answer, touch, focus_session, connect_claude, resize, start_expanded])
        .setup(move |app| {
            tray(app, shared.clone())?;
            if let Some(w) = app.get_webview_window("widget") { place(&w); }
            server::start(app.handle().clone(), shared.clone());
            // Once a second: the window in front, the transcripts (every
            // other tick), holds that ran out, the reset countdown.
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                let mut tick = 0u64;
                loop {
                    std::thread::sleep(Duration::from_secs(1));
                    tick += 1;
                    let title = front::title();
                    {
                        let mut st = ticking.lock();
                        if title.as_deref().is_some_and(|t| !t.contains("Clouding Bar")) { st.front_title = title; }
                        st.expire();
                        st.store.account.expire(SystemTime::now());
                        if tick % 2 == 0 { st.store.poll_transcripts(); }
                        st.update_following();
                        st.remember_followed();
                    }
                    changed(&handle, &ticking);
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Clouding Bar failed to start");
}
