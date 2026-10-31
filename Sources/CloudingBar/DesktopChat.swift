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

    // MARK: Words, with its window where it is

    /// `unsure`: its button was pressed and the words are still in the field.
    /// They may have gone: never sent again, they stay there for you to see.
    /// `busy`: something's in its field already, yours: left alone, and no
    /// keys either, they'd go off with it.
    enum Quiet { case sent, notShown, refused, unsure, busy }

    /// Your words into the chat its window shows, written into its field and
    /// sent by its button, through Accessibility: nothing comes to the front,
    /// no keys. Only into `page`, an empty field, with no question open, and
    /// that's looked at again just before the button. Up to the button
    /// nothing has gone, and what it wrote is taken out again (`notShown`,
    /// `refused`); only its own words, not what you've typed since.
    func sendQuietly(_ text: String, page wanted: String, in app: NSRunningApplication, completion: @escaping (Quiet) -> Void) {
        let pid = app.processIdentifier
        func done(_ result: Quiet) { DispatchQueue.main.async { completion(result) } }
        func bare(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        func same(_ field: AXUIElement) -> Bool { Self.words(field).map(bare) == bare(text) }
        func takeBack(_ field: AXUIElement) {
            if same(field) { _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString) }
        }
        queue.async {
            guard self.shown(pid: pid)?.chat == wanted, let page = self.page, self.findPrompt(pid: pid) == nil,
                  let field = self.composer(in: page), let before = Self.words(field) else { return done(.notShown) }
            guard bare(before).isEmpty else { return done(.busy) }
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success else { return done(.refused) }
            // Chromium's tree follows a moment later; its send button shows once there are words.
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                guard same(field), self.shown(pid: pid)?.chat == wanted, self.findPrompt(pid: pid) == nil,
                      let send = self.sendButton(in: page) else {
                    takeBack(field)
                    return done(.refused)
                }
                guard AXUIElementPerformAction(send, kAXPressAction as CFString) == .success else {
                    takeBack(field)
                    return done(.refused)
                }
                func gone(_ tries: Int) {
                    self.queue.asyncAfter(deadline: .now() + 0.5) {
                        if !same(field) { return done(.sent) }
                        if tries > 0 { gone(tries - 1) } else { done(.unsure) }
                    }
                }
                gone(5)
            }
        }
    }

    /// What's in a field; nil if it can't be told (not the same as empty).
    private static func words(_ field: AXUIElement) -> String? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) {
        case .success: return value as? String
        case .noValue: return ""
        default: return nil
        }
    }

    /// The field at the foot of the chat: from the end of the page, the first
    /// that can take words.
    private func composer(in page: AXUIElement) -> AXUIElement? {
        fromEnd(of: page) { e in
            guard Self.string(e, kAXRoleAttribute) == "AXTextArea" else { return false }
            var settable: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        }
    }

    private func sendButton(in page: AXUIElement) -> AXUIElement? {
        fromEnd(of: page) { e in
            Self.string(e, kAXRoleAttribute) == "AXButton" && ["send", "send message"].contains(Self.label(e)?.lowercased() ?? "")
        }
    }

    private func fromEnd(of page: AXUIElement, where wanted: (AXUIElement) -> Bool) -> AXUIElement? {
        var seen = 0
        var stack: [(AXUIElement, Int)] = [(page, 0)]
        while let (e, depth) = stack.popLast(), seen < 1500 {
            seen += 1
            if wanted(e) { return e }
            guard depth < 45 else { continue }
            stack.append(contentsOf: Self.children(e).map { ($0, depth + 1) }) // the last child comes up first
        }
        return nil
    }

    // MARK: What the chat asks

    /// A question or a permission in the open chat, as Claude Desktop shows
    /// it under the last message — Cowork's too, which no hook reaches.
    struct Prompt: Equatable {
        enum Kind: Equatable { case question, permission }
        let kind: Kind
        /// The question, or what it asks to be allowed.
        let text: String
        /// A question's options; a permission's buttons ("Allow", "Deny").
        let options: [String]
        let multiSelect: Bool
        /// A field for an answer of your own ("Something else").
        let other: Bool
        var key: String { "\(kind)|\(text)|\(options.joined(separator: "\u{1}"))" }
    }

    private var promptBusy = false
    /// Why no question was found, for debug.log (called on `queue`).
    var trace: ((String) -> Void)?

    /// Calls back on the main queue with what the open chat asks, or nil.
    func readPrompt(of app: NSRunningApplication, completion: @escaping (Prompt?) -> Void) {
        guard !promptBusy else { return }
        promptBusy = true
        let pid = app.processIdentifier
        queue.async {
            let prompt = self.findPrompt(pid: pid).map(\.prompt)
            DispatchQueue.main.async {
                self.promptBusy = false
                completion(prompt)
            }
        }
    }

    /// Answers it there: presses the option (or each picked one, then the
    /// button that sends them) or the permission's button. An answer of
    /// your own goes into its field, typed with Claude in front. Calls back
    /// on the main queue with whether it was done.
    func answer(_ prompt: Prompt, choices: [String], own: String?, in app: NSRunningApplication,
                completion: @escaping (Bool) -> Void) {
        let pid = app.processIdentifier
        queue.async {
            guard let found = self.findPrompt(pid: pid), found.prompt.key == prompt.key else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            var done = true
            for choice in choices {
                // The very label first: "Allow" must not press "Allow always".
                guard let e = found.controls.first(where: { Self.label($0)?.lowercased() == choice.lowercased() })
                        ?? found.controls.first(where: { Self.label($0).map { Self.same($0, choice) } ?? false }) else {
                    done = false
                    continue
                }
                done = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success && done
            }
            if prompt.multiSelect, own == nil, let send = found.send {
                done = AXUIElementPerformAction(send, kAXPressAction as CFString) == .success && done
            }
            if let own, let field = found.field {
                self.answerOwn(own, field: field, prompt: prompt, pid: pid, app: app, completion: completion)
                return
            }
            DispatchQueue.main.async { completion(done) }
        }
    }

    /// Your own words for a question: written into its field and sent from
    /// here, Claude's window left where it is (owner, 26.10: answering took
    /// him to that window and nothing went). Only if that can't be done here,
    /// the window comes forward for the words to be typed — never into
    /// another app — and you're taken back. Never typed twice. Done when the
    /// question is gone. On `queue`.
    private func answerOwn(_ own: String, field: AXUIElement, prompt: Prompt, pid: pid_t, app: NSRunningApplication,
                           completion: @escaping (Bool) -> Void) {
        let set = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, own as CFString) == .success
        queue.asyncAfter(deadline: .now() + 0.3) {
            // Its send button shows once there are words in the field.
            var sent = false
            if set {
                if let send = self.findPrompt(pid: pid).flatMap({ $0.prompt.key == prompt.key ? $0.send : nil }) {
                    sent = AXUIElementPerformAction(send, kAXPressAction as CFString) == .success
                } else {
                    sent = AXUIElementPerformAction(field, kAXConfirmAction as CFString) == .success
                }
            }
            if sent {
                // Sent from here: the card may stay a few seconds (it does for
                // the bar's own answers); not typed again whatever happens.
                self.waitGone(pid: pid, prompt: prompt, until: Date().addingTimeInterval(6)) { gone in
                    DebugLog.note("desktop prompt: own answer sent from here" + (gone ? "" : ", but the question is still there"))
                    DispatchQueue.main.async { completion(gone) }
                }
                return
            }
            DebugLog.note("desktop prompt: own answer couldn't be sent from here (value \(set ? "set" : "refused")): typed in Claude's window")
            // What was set here goes, so the words aren't there twice.
            if set { _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString) }
            DispatchQueue.main.async {
                let before = NSWorkspace.shared.frontmostApplication
                app.activate(options: [])
                self.queue.asyncAfter(deadline: .now() + 0.4) {
                    // Keys only into Claude's own field, with its question still there.
                    let focused = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
                    let asking = self.findPrompt(pid: pid)?.prompt.key == prompt.key
                    DispatchQueue.main.async {
                        guard focused, asking, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                            DebugLog.note("desktop prompt: nothing typed (field \(focused ? "focused" : "not focused"), question \(asking ? "there" : "gone"))")
                            completion(!asking)
                            return
                        }
                        KeySender.type(own, pressReturn: true)
                        self.queue.async {
                            self.waitGone(pid: pid, prompt: prompt, until: Date().addingTimeInterval(6)) { gone in
                                DispatchQueue.main.async {
                                    if let before, before.processIdentifier != pid { before.activate(options: []) }
                                    completion(gone)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Looks every half second until the question is gone or time's up. On `queue`.
    private func waitGone(pid: pid_t, prompt: Prompt, until: Date, done: @escaping (Bool) -> Void) {
        if findPrompt(pid: pid)?.prompt.key != prompt.key { done(true); return }
        guard Date() < until else { done(false); return }
        queue.asyncAfter(deadline: .now() + 0.5) { self.waitGone(pid: pid, prompt: prompt, until: until, done: done) }
    }

    private struct Found {
        let prompt: Prompt
        /// The options or the permission's buttons, to press.
        let controls: [AXUIElement]
        let field: AXUIElement?
        /// The button that sends picked options.
        let send: AXUIElement?
    }

    private static let questionMark = "Asking a question"
    private static let allowWords = ["allow", "approve", "always allow", "allow once", "allow always"]
    private static let denyWords = ["deny", "don't allow", "do not allow", "decline", "reject"]
    private static let sendWords = ["submit", "next", "continue", "send", "done"]
    /// Every message's own toggles and names, not a question's.
    private static let notOptions: Set<String> = ["good response", "bad response"]
    private static func isMessageName(_ s: String) -> Bool {
        s.hasPrefix("Message ") && s.contains(" of ") && s.split(separator: " ").count == 4
    }

    static func allows(_ label: String) -> Bool { allowWords.contains(label.lowercased()) }
    static func denies(_ label: String) -> Bool { denyWords.contains(label.lowercased()) }

    /// "Chrome Google Chrome" is the option "Chrome"; case and spaces aside.
    private static func same(_ label: String, _ choice: String) -> Bool {
        let a = label.lowercased(), b = choice.lowercased()
        return a == b || a.hasPrefix(b + " ")
    }

    private func findPrompt(pid: pid_t) -> Found? {
        if page == nil { _ = shown(pid: pid) }
        guard let page else { trace?("no claude.ai page"); return nil }
        // From the end of the page, where the last message and its question
        // are: "Asking a question", or a button that allows something.
        var mark: AXUIElement?
        var kind = Prompt.Kind.question
        var seen = 0
        var stack: [(AXUIElement, Int)] = [(page, 0)]
        while let (e, depth) = stack.popLast(), seen < 1500 { // the end of the page is enough
            seen += 1
            let role = Self.string(e, kAXRoleAttribute) ?? ""
            let label = Self.label(e) ?? ""
            // The answer box itself — its Skip, its field for an answer of your
            // own — not the "Asking a question" line in the message above it.
            if (role == "AXButton" && label.lowercased() == "skip") || (role == "AXTextField" && label == "Something else") {
                mark = e
                kind = .question
                break
            }
            if role == "AXButton", Self.allowWords.contains(label.lowercased()) { mark = e; kind = .permission; break }
            guard depth < 45 else { continue }
            stack.append(contentsOf: Self.children(e).map { ($0, depth + 1) }) // the last child comes up first
        }
        guard let mark else { trace?("nothing asked (\(seen) elements looked at)"); return nil }
        // Up to the part of the page that holds the options too.
        var box: AXUIElement? = mark
        for _ in 0..<6 {
            guard let up = box.flatMap({ Self.element($0, kAXParentAttribute) }) else { break }
            box = up
            if let found = read(up, kind: kind) { return found }
        }
        trace?("\(kind == .question ? "Skip or Something else" : "an Allow button") found, but no options around it")
        return nil
    }

    /// The question (or permission) in `box`, if it's all there.
    private func read(_ box: AXUIElement, kind: Prompt.Kind) -> Found? {
        var texts: [String] = []
        var options: [(String, AXUIElement)] = []
        var buttons: [(String, AXUIElement)] = []
        var field: AXUIElement?
        walk(box, into: { _ in true }) { e in
            let role = Self.string(e, kAXRoleAttribute) ?? ""
            let label = CFEqual(e, box) ? "" : Self.label(e) ?? "" // the part's own name ("Message 42 of 42") isn't the question
            switch role {
            case "AXCheckBox", "AXRadioButton":
                if !label.isEmpty, !Self.notOptions.contains(label.lowercased()) { options.append((label, e)) }
            case "AXButton":
                if !label.isEmpty { buttons.append((label, e)) }
            case "AXTextField":
                field = e
            case "AXStaticText", "AXHeading", "AXGroup":
                if !label.isEmpty, label != Self.questionMark, !Self.isMessageName(label), !texts.contains(label) {
                    texts.append(label)
                }
            default:
                break
            }
            return true
        }
        let buttonLabels = Set(buttons.map { $0.0 })
        let words = texts.filter { !buttonLabels.contains($0) && !options.map(\.0).contains($0) }
        switch kind {
        case .question:
            // Waiting for an answer: Skip, or a field for one of your own.
            let waiting = field != nil || buttons.contains { $0.0.lowercased() == "skip" }
            guard waiting, !options.isEmpty, let question = words.first else { return nil }
            let send = buttons.first { Self.sendWords.contains($0.0.lowercased()) }?.1
            let prompt = Prompt(kind: .question, text: question, options: options.map { $0.0 },
                                multiSelect: send != nil, other: field != nil)
            return Found(prompt: prompt, controls: options.map { $0.1 }, field: field, send: send)
        case .permission:
            let allow = buttons.filter { Self.allowWords.contains($0.0.lowercased()) }
            let deny = buttons.filter { Self.denyWords.contains($0.0.lowercased()) }
            guard !allow.isEmpty, !deny.isEmpty else { return nil }
            let prompt = Prompt(kind: .permission, text: words.prefix(3).joined(separator: " · "),
                                options: (allow + deny).map { $0.0 }, multiSelect: false, other: false)
            return Found(prompt: prompt, controls: (allow + deny).map { $0.1 }, field: nil, send: nil)
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
