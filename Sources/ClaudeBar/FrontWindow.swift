import AppKit
import ApplicationServices

/// Reads the title of the frontmost window ("Makefile — claudebar — Visual
/// Studio Code"), which tells which project is in front. Uses the
/// Accessibility permission the app already has for typing. Runs off the
/// main thread with a short timeout, so a busy app can't stall the bar.
final class FrontWindow {
    private let queue = DispatchQueue(label: "claudebar.front-window", qos: .userInitiated)
    private var busy = false

    /// Calls back on the main queue with the title, or nil.
    func readTitle(of app: NSRunningApplication, completion: @escaping (String?) -> Void) {
        guard !busy else { return }
        busy = true
        let pid = app.processIdentifier
        queue.async {
            let title = Self.title(pid: pid)
            DispatchQueue.main.async {
                self.busy = false
                completion(title)
            }
        }
    }

    private static func title(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
}
