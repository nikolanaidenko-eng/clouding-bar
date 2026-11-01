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
        /// The page's path, "/chat/abcd5678-…": the chat itself.
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

    /// Its window over to the task called `title`, by its row, for words
    /// waiting for it: not while the task it shows asks you something or has
    /// words in its field. Calls back on the main queue with what came of it.
    /// `shown`: it shows the task already, nothing pressed.
    enum Switched: Equatable { case went, shown, stays(String), noRow }

    /// `leaving`: the task it shows may be left even while it asks something
    /// (an answer for another task is wanted: the question there stays).
    func switchTo(title: String?, from wanted: String, in app: NSRunningApplication, leaving: Bool = false,
                  completion: @escaping (Switched) -> Void) {
        let pid = app.processIdentifier
        func done(_ result: Switched) { DispatchQueue.main.async { completion(result) } }
        queue.async {
            // Its page not read: nothing can be told of what's there (review 01.11).
            guard let shown = self.shown(pid: pid), let page = self.page else {
                return done(.stays("Desktop's page can't be read yet: these wait"))
            }
            guard shown.chat != wanted else { return done(.shown) }
            let asking = !leaving && self.findPrompt(pid: pid) != nil
            // A chat with no field found: can't be told, so not left; a page
            // that has none (its list of tasks, settings) has no draft to lose.
            let conversation = shown.chat.hasPrefix("/chat/") || shown.chat.hasPrefix("/cowork/") || shown.chat.hasPrefix("/epitaxy/")
            let draft = self.composer(in: page).flatMap { Self.words($0) } ?? (conversation ? nil : "")
            guard LocalCowork.mayLeave(asking: asking, draft: draft) else {
                let why = asking ? "it asks something" : draft == nil ? "its field can't be read" : "words in its field"
                DebugLog.note("local cowork: its window left where it is: \(why)")
                return done(.stays(asking ? "Another task asks something in Desktop: these wait"
                                   : draft == nil ? "Desktop's field can't be read: these wait" : "Words in another task's field in Desktop: these wait"))
            }
            // One at a time, its page telling whether that was it (measured
            // 01.11: the one chat is listed under its project and in Recents,
            // and another chat may carry the same name). Never under your
            // hands: Desktop in front, looked at before each press (review 01.11).
            for (n, row) in self.rows(for: title, page: wanted, pid: pid, app: app).prefix(3).enumerated() {
                guard !app.isActive else { return done(.stays(Self.inFrontNote)) }
                guard AXUIElementPerformAction(row, kAXPressAction as CFString) == .success else { continue }
                if self.pageCame(wanted, pid: pid) { return done(.went) }
                DebugLog.note("local cowork: row \(n + 1) pressed, its page didn't come (it shows \(self.shown(pid: pid)?.chat.prefix(14) ?? "nothing"))")
            }
            done(app.isActive ? .stays(Self.inFrontNote) : .noRow)
        }
    }

    static let inFrontNote = "You're in Desktop: these wait"

    /// A press in its page with the window in the back is taken up at the
    /// next event only (measured 01.11, 4.4212: a row pressed, the page
    /// stayed for 20 s; the next press or a scroll, and it went). Scrolling
    /// the page to itself is that event, and changes nothing. On `queue`.
    private func nudge() {
        if let page { _ = AXUIElementPerformAction(page, "AXScrollToVisible" as CFString) }
    }

    /// After a row is pressed: nudged, then up to 3 s for its page. On `queue`.
    private func pageCame(_ wanted: String, pid: pid_t) -> Bool {
        for _ in 0..<6 {
            nudge()
            Thread.sleep(forTimeInterval: 0.5)
            if shown(pid: pid)?.chat == wanted { return true }
        }
        return false
    }

    /// When its rows were last written to debug.log, with nothing found.
    private var rowsSampled = Date.distantPast

    /// The task's rows in Desktop's window, to press in turn. Its list isn't
    /// links (4.29: links with their page; 4.4212, measured 01.11: a button
    /// "<name> Unread response" with the name in a text inside): anything
    /// named, pressed itself or by what holds it. The list is in its sidebar,
    /// shut by default (01.11): opened by its View menu, from the back too;
    /// with Desktop on a chat, its Cowork tab first. On `queue`.
    private func rows(for title: String?, page wanted: String, pid: pid_t, app: NSRunningApplication, again: Bool = true) -> [AXUIElement] {
        var rows: [LocalCowork.Row] = []
        var elements: [AXUIElement] = []
        // The tab its list is in: a Claude Code chat's is Code.
        let code = wanted.hasPrefix("/epitaxy/")
        let tabName = code ? "code" : "cowork"
        let tabNames = code ? LocalCowork.codeTabNames : LocalCowork.coworkTabNames
        for window in windows(pid: pid) {
            walk(window, into: { _ in true }) { e in
                let role = Self.string(e, kAXRoleAttribute) ?? ""
                let label = Self.label(e) ?? ""
                let path = (Self.value(e, "AXURL") as? URL)?.path
                guard !label.isEmpty || path != nil else { return true }
                // Only a likely row is asked whether it can be pressed: that's a call each.
                let likely = path == wanted || (title.map { SessionStore.titleScore(label, $0) == 3 } ?? false) || tabNames.contains(label.lowercased())
                let pressable = ["AXLink", "AXButton"].contains(role) || (likely && Self.canPress(e))
                rows.append(LocalCowork.Row(role: role, label: label, path: path, pressable: pressable))
                elements.append(e)
                return true
            }
        }
        var found: [AXUIElement] = []
        for i in LocalCowork.rowCandidates(rows, title: title, page: wanted) {
            if rows[i].pressable { found.append(elements[i]); continue }
            // Its name alone, in a row that's pressed as a whole.
            var up: AXUIElement? = elements[i]
            for _ in 0..<6 {
                up = up.flatMap { Self.element($0, kAXParentAttribute) }
                guard let e = up else { break }
                if Self.canPress(e) {
                    if !found.contains(where: { CFEqual($0, e) }) { found.append(e) }
                    break
                }
            }
        }
        if !found.isEmpty { return found }
        let sidebar = LocalCowork.sidebar(rows)
        // The menu's "Show Sidebar" is a toggle, and says nothing of its state
        // (measured 01.11: the same name, no mark, open or shut): pressed only
        // with the sidebar shut for sure, Desktop in the back, once in a while.
        if again, sidebar == .shut, page != nil, !app.isActive, Date().timeIntervalSince(sidebarPressed) > 300, showSidebar(pid: pid) {
            sidebarPressed = Date()
            nudge()
            Thread.sleep(forTimeInterval: 0.6)
            nudge()
            Thread.sleep(forTimeInterval: 0.6)
            let after = self.rows(for: title, page: wanted, pid: pid, app: app, again: false)
            DebugLog.note("local cowork: its sidebar opened by the menu: \(sidebarSeen == .open ? "open now" : "not seen open"), \(after.isEmpty ? "no row" : "its row found")")
            return after
        }
        if again, let tab = LocalCowork.coworkTab(rows, named: tabNames), shown(pid: pid)?.chat.hasPrefix(code ? "/epitaxy/" : "/cowork/") != true, !app.isActive,
           AXUIElementPerformAction(elements[tab], kAXPressAction as CFString) == .success {
            DebugLog.note("local cowork: its \(tabName) tab pressed, the list looked at again")
            nudge()
            Thread.sleep(forTimeInterval: 0.6)
            nudge()
            Thread.sleep(forTimeInterval: 0.6)
            return self.rows(for: title, page: wanted, pid: pid, app: app, again: false)
        }
        sidebarSeen = sidebar
        let exact = title.map { t in rows.filter { SessionStore.titleScore($0.label, t) == 3 }.count } ?? 0
        let alike = title.map { t in rows.filter { SessionStore.sameTitle($0.label, t) }.count } ?? 0
        DebugLog.note("local cowork: no one row for it (\(rows.count) named in its window, \(exact) exact, \(alike) alike, name \(title != nil ? "known" : "unknown"), sidebar \(sidebar))")
        if Date().timeIntervalSince(rowsSampled) > 60 {
            rowsSampled = Date()
            DebugLog.note("local cowork: rows seen: " + LocalCowork.rowsSample(rows, title: title))
        }
        return []
    }

    /// When the sidebar's toggle was last pressed, and what the list said after.
    private var sidebarPressed = Date.distantPast
    private var sidebarSeen = LocalCowork.Sidebar.unknown

    /// View › Show Sidebar in Desktop's own menu bar: pressed through
    /// Accessibility, which works with the app in the back (measured 01.11).
    private func showSidebar(pid: pid_t) -> Bool {
        guard let bar = Self.element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return false }
        for menu in Self.children(bar) where Self.string(menu, kAXTitleAttribute) == "View" {
            for sub in Self.children(menu) {
                for item in Self.children(sub) where Self.string(item, kAXTitleAttribute) == "Show Sidebar" {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func canPress(_ e: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success, let actions = names as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    /// `unsure`: its button was pressed and the words are still in the field.
    /// They may have gone: never sent again, they stay there for you to see.
    /// `busy`: something's in its field already, yours: left alone, and no
    /// keys either, they'd go off with it. `asking`: the task it shows asks
    /// you something: first that.
    enum Quiet { case sent, notShown, refused, unsure, busy(Int), asking }

    /// On `queue`: the words sent last.
    private var lastSent: (words: String, at: Date)?
    /// What we wrote into its field and haven't pressed Send on: still there
    /// after a failed try it's ours, not a draft (owner's Mac, 01.11: `busy(14)`
    /// to every Send now, held back by its own words).
    private var lastUnsent: String?

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
            if same(field) {
                _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
                self.nudge()
            }
        }
        func start(_ tries: Int) {
            guard self.shown(pid: pid)?.chat == wanted, let page = self.page else { return done(.notShown) }
            guard self.findPrompt(pid: pid) == nil else { return done(.asking) }
            guard let field = self.composer(in: page), let before = Self.words(field) else { return done(.notShown) }
            switch LocalCowork.field(before, sent: self.lastSent, unsent: self.lastUnsent) {
            case .empty, .unsent: break
            case .late where tries > 0:
                self.queue.asyncAfter(deadline: .now() + 0.5) { start(tries - 1) }
                return
            default: return done(.busy(before.count))
            }
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success else { return done(.refused) }
            let written = Date()
            self.lastSent = nil
            self.lastUnsent = text
            func gone(_ tries: Int) {
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    self.nudge()
                    if !same(field) { return done(.sent) }
                    if tries > 0 { gone(tries - 1) } else { done(.unsure) }
                }
            }
            // Chromium's tree follows late with its window in the background
            // (owner's Mac, 31.10: gave up at 0.5 s, words gone only after 3.5 s);
            // its send button shows once there are words. With the window in the
            // back the page moves at the next event only, and an event right after
            // the write is too soon (measured 01.11, 4.4212, Cowork's field: one
            // nudge, empty and no Send for 5 s; one at each look, both in 0.6 s).
            func press(_ tries: Int) {
                self.queue.asyncAfter(deadline: .now() + 0.3) {
                    self.nudge()
                    let shown = self.shown(pid: pid)
                    let asking = self.findPrompt(pid: pid) != nil
                    guard !asking, shown == nil || shown?.chat == wanted else {
                        DebugLog.note("local cowork: not sent, \(asking ? "it asks something" : "its window went to another task")")
                        takeBack(field)
                        return done(.refused)
                    }
                    let there = same(field)
                    guard shown != nil, there, let send = self.sendButton(in: page) else {
                        if tries > 0 { return press(tries - 1) }
                        DebugLog.note("local cowork: not sent, page \(shown != nil), words \(there), no Send after 3.6 s")
                        takeBack(field)
                        return done(.refused)
                    }
                    DebugLog.note("local cowork: Send pressed \(Int(Date().timeIntervalSince(written) * 1000)) ms after the words")
                    guard AXUIElementPerformAction(send, kAXPressAction as CFString) == .success else {
                        takeBack(field)
                        return done(.refused)
                    }
                    self.lastSent = (text, Date())
                    self.lastUnsent = nil
                    self.nudge()
                    gone(19)
                }
            }
            press(11)
        }
        queue.async { start(24) }
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
            Self.string(e, kAXRoleAttribute) == "AXButton" && LocalCowork.isSend(label: Self.label(e))
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
        /// The chat its page showed when it was read ("/cowork/local_…"):
        /// the task it asks in, with the app in the back too (review 01.11).
        var page: String? = nil
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
            self.press(found, choices: choices, own: own, pid: pid, app: app, completion: completion)
        }
    }

    /// An answer read from a task's own events, for the question its window
    /// shows now — the task's page, with that very question (its options) on
    /// it. Calls back on the main queue: nil when the page or the question
    /// isn't there (nothing pressed), else whether it was done.
    /// What came of an answer from a task's events on its page.
    enum Answered: Equatable {
        case done, failed
        /// The page or the question isn't there (nothing pressed).
        case notThere
        /// The question before it (`after`) is still up: not yet (nothing pressed).
        case stillPrevious
    }

    /// An answer read from a task's own events, for the question its window
    /// shows now — the task's page, with that very question (its options,
    /// the window's with their descriptions after them) on it; `after`: the
    /// question answered just before, which the window may show a moment
    /// longer (review 01.11: the next answer pressed into it). Calls back on
    /// the main queue. Nothing of Desktop's brought forward.
    func answerShown(page wanted: String, question: QuestionItem, answer: String, after previous: String?, in app: NSRunningApplication,
                     completion: @escaping (Answered) -> Void) {
        let pid = app.processIdentifier
        queue.async {
            guard self.shown(pid: pid)?.chat == wanted, let found = self.findPrompt(pid: pid), found.prompt.kind == .question else {
                self.nudge() // a press before may not have been taken up yet
                DispatchQueue.main.async { completion(.notThere) }
                return
            }
            if let previous, found.prompt.key == previous {
                self.nudge()
                DispatchQueue.main.async { completion(.stillPrevious) }
                return
            }
            guard LocalCowork.sameQuestion(found.prompt.options, question.options) else {
                DispatchQueue.main.async { completion(.notThere) }
                return
            }
            let parts = answer.components(separatedBy: ", ")
            let choices = question.options.contains(answer) ? [answer] : parts.allSatisfy(question.options.contains) ? parts : []
            self.press(found, choices: choices, own: choices.isEmpty ? answer : nil, pid: pid, app: app, mayActivate: false) { done in
                completion(done ? .done : .failed)
            }
        }
    }

    /// Presses the options (or each picked one, then the button that sends
    /// them) or the permission's button; your own words into its field. On `queue`.
    private func press(_ found: Found, choices: [String], own: String?, pid: pid_t, app: NSRunningApplication, mayActivate: Bool = true,
                       completion: @escaping (Bool) -> Void) {
        let prompt = found.prompt
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
        if let own {
            // Words of your own with no field for them: not done, not lost (review 01.11).
            guard let field = found.field else {
                DebugLog.note("desktop prompt: words of your own, but the question has no field for them")
                DispatchQueue.main.async { completion(false) }
                return
            }
            answerOwn(own, field: field, prompt: prompt, pid: pid, app: app, mayActivate: mayActivate, completion: completion)
            return
        }
        nudge()
        DispatchQueue.main.async { completion(done) }
    }

    /// Your own words for a question: written into its field and sent from
    /// here, Claude's window left where it is (owner, 26.10: answering took
    /// him to that window and nothing went). Only if that can't be done here
    /// and `mayActivate` (a question read from its window, the old way),
    /// the window comes forward for the words to be typed — never into
    /// another app — and you're taken back; else it's not done. Never typed
    /// twice. Done when the question is gone. On `queue`.
    private func answerOwn(_ own: String, field: AXUIElement, prompt: Prompt, pid: pid_t, app: NSRunningApplication, mayActivate: Bool,
                           completion: @escaping (Bool) -> Void) {
        let set = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, own as CFString) == .success
        // Taken up at the next event with the window in the back; its send
        // button shows once the words are there, up to 3.6 s (as sendQuietly).
        if set { nudge() }
        func trySend(_ tries: Int) {
            queue.asyncAfter(deadline: .now() + 0.3) {
                guard set else { return notSent(set: false) }
                let there = Self.words(field).map { $0.filter { !$0.isWhitespace } == own.filter { !$0.isWhitespace } } ?? false
                if let send = self.findPrompt(pid: pid).flatMap({ $0.prompt.key == prompt.key ? $0.send : nil }), there,
                   AXUIElementPerformAction(send, kAXPressAction as CFString) == .success {
                    return sent()
                }
                if tries > 0 { return trySend(tries - 1) }
                if there, AXUIElementPerformAction(field, kAXConfirmAction as CFString) == .success { return sent() }
                notSent(set: true)
            }
        }
        func sent() {
            self.nudge()
            // Sent from here: the card may stay a few seconds (it does for
            // the bar's own answers); not typed again whatever happens.
            self.waitGone(pid: pid, prompt: prompt, until: Date().addingTimeInterval(6)) { gone in
                DebugLog.note("desktop prompt: own answer sent from here" + (gone ? "" : ", but the question is still there"))
                DispatchQueue.main.async { completion(gone) }
            }
        }
        func notSent(set: Bool) {
            // What was set here goes, so the words aren't there twice.
            if set { _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString); self.nudge() }
            guard mayActivate else {
                DebugLog.note("desktop prompt: own answer couldn't be sent from here (value \(set ? "set" : "refused")): asked again on the bar")
                DispatchQueue.main.async { completion(false) }
                return
            }
            DebugLog.note("desktop prompt: own answer couldn't be sent from here (value \(set ? "set" : "refused")): typed in Claude's window")
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
        trySend(11)
    }

    /// Looks every half second until the question is gone or time's up. On `queue`.
    private func waitGone(pid: pid_t, prompt: Prompt, until: Date, done: @escaping (Bool) -> Void) {
        if findPrompt(pid: pid)?.prompt.key != prompt.key { done(true); return }
        guard Date() < until else { done(false); return }
        queue.asyncAfter(deadline: .now() + 0.5) { self.waitGone(pid: pid, prompt: prompt, until: until, done: done) }
    }

    private struct Found {
        var prompt: Prompt
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
            if var found = read(up, kind: kind) {
                found.prompt.page = Self.read(page)?.chat
                return found
            }
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
        guard Date().timeIntervalSince(lastSearch) > 3 else { return nil }
        lastSearch = Date()
        for window in windows(pid: pid) where page == nil {
            walk(window, into: { Self.string($0, kAXRoleAttribute) != "AXWebArea" || Self.read($0) == nil }) { e in
                if Self.string(e, kAXRoleAttribute) == "AXWebArea", Self.read(e) != nil {
                    page = e
                    return false
                }
                return true
            }
        }
        guard page == nil else { return page.flatMap(Self.read) }
        tellWhyNoPage(pid: pid)
        // Its tree can go off on the way (its own log says so) or not have
        // come on: asked again at the next look.
        enabled.remove(pid)
        return nil
    }

    private var lastWhy: (at: Date, why: String)?

    /// For debug.log, at most once a minute: what its windows hold. No names.
    private func tellWhyNoPage(pid: pid_t) {
        guard Date().timeIntervalSince(lastWhy?.at ?? .distantPast) > 60 else { return }
        var buttons = 0, areas: [String] = []
        let windows = windows(pid: pid)
        for window in windows {
            walk(window, into: { _ in true }) { e in
                let role = Self.string(e, kAXRoleAttribute)
                if role == "AXButton" { buttons += 1 }
                if role == "AXWebArea" {
                    let url = Self.value(e, "AXURL") as? URL
                    areas.append("\(url?.host ?? "-")/\(url?.pathComponents.dropFirst().first ?? "-") (\(url?.pathComponents.count ?? 0))")
                }
                return true
            }
        }
        let version = NSRunningApplication(processIdentifier: pid)?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?"
        let why = "Desktop \(version), tree switch \(switchResult), \(windows.count) window(s), \(buttons) button(s), pages \(areas)"
        guard why != lastWhy?.why else { return }
        lastWhy = (Date(), why)
        DebugLog.note("desktop page: none. " + why)
    }

    /// A claude.ai page: its chat and title.
    private static func read(_ page: AXUIElement) -> Shown? {
        guard let url = value(page, "AXURL") as? URL, LocalCowork.isPage(url) else { return nil }
        var title = string(page, kAXTitleAttribute) ?? ""
        if title.hasSuffix(" - Claude") { title = String(title.dropLast(" - Claude".count)) }
        title = title.trimmingCharacters(in: .whitespaces)
        return Shown(title: title.isEmpty || title == "Claude" ? nil : title, chat: url.path)
    }

    /// The app, with Chromium's tree turned on. Busy, it may not hear that
    /// in time: only an answer counts.
    private func application(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        if !enabled.contains(pid) {
            let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            switchResult = result.rawValue
            if result == .success { enabled.insert(pid) }
        }
        return app
    }

    /// The last answer to turning its tree on, for debug.log.
    private var switchResult: Int32 = 0

    /// The front window.
    private func root(pid: pid_t) -> AXUIElement? { windows(pid: pid).first }

    /// Its windows, the front one first. On another Space or behind, one is
    /// in none of the lists but the focused or the main (measured, 31.10).
    private func windows(pid: pid_t) -> [AXUIElement] {
        let app = application(pid: pid)
        var found: [AXUIElement] = []
        let all = [element(app, kAXFocusedWindowAttribute), element(app, kAXMainWindowAttribute)].compactMap { $0 }
            + ((Self.value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [])
        for window in all where !found.contains(where: { CFEqual($0, window) }) { found.append(window) }
        return found
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
