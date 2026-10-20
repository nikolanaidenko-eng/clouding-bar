import AppKit
import ApplicationServices

/// Claude Desktop's window is always called "Claude"; which chat it shows
/// is in its page: titled "⚡ Threads: leads - Claude", at
/// claude.ai/chat/<id>. Read — and its sidebar row pressed, to open a chat —
/// through Accessibility, which Chromium builds once AXManualAccessibility
/// is on. Off the main thread with short timeouts, so a busy app can't
/// stall the bar.
final class DesktopChat {
    struct Shown: Equatable {
        /// "Threads: leads"; nil while the page loads.
        let title: String?
        /// The page's path, "/chat/64a92e6f-…": the chat itself.
        let chat: String
    }

    private let queue = DispatchQueue(label: "cloudingbar.desktop-chat", qos: .userInitiated)
    private var busy = false
    // Below: only on `queue`.
    /// The claude.ai page found last time; most reads only ask it again.
    private var page: AXUIElement?
    private var lastSearch = Date.distantPast
    private var enabled: Set<pid_t> = []

    /// Calls back on the main queue with the chat shown, or nil.
    func readOpenChat(of app: NSRunningApplication, completion: @escaping (Shown?) -> Void) {
        guard !busy else { return }
        busy = true
        let pid = app.processIdentifier
        queue.async {
            let shown = self.shown(pid: pid)
            DispatchQueue.main.async {
                self.busy = false
                completion(shown)
            }
        }
    }

    /// Presses the sidebar row that names this chat. Calls back on the main
    /// queue with whether there was one.
    func open(title: String, in app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        let pid = app.processIdentifier
        queue.async {
            var row: AXUIElement?
            if let root = self.root(pid: pid) {
                self.walk(root, into: { _ in true }) { e in
                    if Self.string(e, kAXRoleAttribute) == "AXButton", let t = Self.label(e), SessionStore.sameTitle(t, title) {
                        row = e
                        return false
                    }
                    return true
                }
            }
            let pressed = row.map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
            DispatchQueue.main.async { completion(pressed) }
        }
    }

    private func shown(pid: pid_t) -> Shown? {
        if let page, let shown = Self.read(page) { return shown }
        page = nil
        // Look for the page, at most every few seconds. It isn't entered:
        // what's in it (a long chat) can be a big tree. The app's own shell
        // page, which may hold it, is.
        guard Date().timeIntervalSince(lastSearch) > 3, let root = root(pid: pid) else { return nil }
        lastSearch = Date()
        walk(root, into: { Self.string($0, kAXRoleAttribute) != "AXWebArea" || Self.read($0) == nil }) { e in
            if Self.string(e, kAXRoleAttribute) == "AXWebArea", Self.read(e) != nil {
                page = e
                return false
            }
            return true
        }
        return page.flatMap(Self.read)
    }

    /// A claude.ai page: its chat and title.
    private static func read(_ page: AXUIElement) -> Shown? {
        guard let url = value(page, "AXURL") as? URL, url.host?.hasSuffix("claude.ai") == true,
              url.pathComponents.count >= 3 else { return nil }
        var title = string(page, kAXTitleAttribute) ?? ""
        if title.hasSuffix(" - Claude") { title = String(title.dropLast(" - Claude".count)) }
        title = title.trimmingCharacters(in: .whitespaces)
        return Shown(title: title.isEmpty || title == "Claude" ? nil : title, chat: url.path)
    }

    /// The front window, with Chromium's tree turned on.
    private func root(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        if !enabled.contains(pid) {
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabled.insert(pid)
        }
        return element(app, kAXFocusedWindowAttribute)
            ?? (Self.value(app, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    private func element(_ e: AXUIElement, _ name: String) -> AXUIElement? { Self.element(e, name) }

    /// Depth first, until `visit` says stop, entering only what `into`
    /// allows; bounded, as a long chat is a big tree.
    private func walk(_ root: AXUIElement, into: (AXUIElement) -> Bool, visit: (AXUIElement) -> Bool) {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var seen = 0
        while let item = stack.popLast(), seen < 6000 {
            let (e, depth) = item
            seen += 1
            if !visit(e) { return }
            guard depth < 45, depth == 0 || into(e) else { continue }
            stack.append(contentsOf: Self.children(e).reversed().map { ($0, depth + 1) })
        }
    }

    private static func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? { value(e, name) as? String }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        value(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func label(_ e: AXUIElement) -> String? {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let t = string(e, name)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        }
        return nil
    }
}
