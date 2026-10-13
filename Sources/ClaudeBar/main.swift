import AppKit

// ClaudeBar runs as a menu bar accessory — no Dock icon, no windows.
// All the interesting stuff happens on the Touch Bar.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
