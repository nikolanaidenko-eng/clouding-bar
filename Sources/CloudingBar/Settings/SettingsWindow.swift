import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// The settings window: 600 wide, 560 tall to start and as tall as you
/// pull it, light or dark; closed, minimized or zoomed (owner, 26.10).
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    private var watch: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Clouding Bar Settings"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = .adaptive(light: 0xF2F2F5, dark: 0x232325)
            w.acceptsMouseMovedEvents = true // Cloud follows the pointer
            // As wide as its tabs are laid out for; taller as you like.
            w.contentMinSize = NSSize(width: SettingsView.width, height: 420)
            w.contentMaxSize = NSSize(width: SettingsView.width, height: 10_000)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
            watch = model.$config.map(\.appearance).removeDuplicates().sink { [weak w] value in
                w?.appearance = value == "light" ? NSAppearance(named: .aqua)
                    : value == "dark" ? NSAppearance(named: .darkAqua) : nil
            }
        }
        // A Dock icon while it's open: minimized, it comes back from there.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Settings itself has the keyboard (not the widget or the bar's own).
    var isKey: Bool { window?.isKeyWindow ?? false }

    func windowWillClose(_ notification: Notification) {
        // A closed window's views don't all hear of it: the Touch Bar goes
        // back to its usual self here.
        model.editingShortBar = false
        model.tourStep = nil // closed midway: Settings opens as Settings next time
        SettingsFolds.shared.reset() // General's groups are folded again next time (owner, 27.10)
        NSApp.setActivationPolicy(.accessory)
    }
}

/// "Open at login" through the system's login items (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool {
        guard #available(macOS 13, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        guard #available(macOS 13, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Clouding Bar: login item — \(error.localizedDescription)")
        }
    }
}
