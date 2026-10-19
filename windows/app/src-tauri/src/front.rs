//! The title of the window in front ("main.rs — DiaRoute — Visual Studio
//! Code"), which says which project — and so which session — is in front.

#[cfg(windows)]
pub fn title() -> Option<String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowTextW};
    unsafe {
        let window = GetForegroundWindow();
        if window.is_null() {
            return None;
        }
        let mut buf = [0u16; 512];
        let n = GetWindowTextW(window, buf.as_mut_ptr(), buf.len() as i32);
        (n > 0).then(|| String::from_utf16_lossy(&buf[..n as usize]))
    }
}

/// Elsewhere (developing on a Mac): the latest session stands in.
#[cfg(not(windows))]
pub fn title() -> Option<String> {
    None
}
