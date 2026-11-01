import Foundation

/// Cowork tasks that run on this Mac, as Claude Desktop keeps them (an
/// organization on the API has them nowhere on claude.ai, owner, 31.10):
/// local-agent-mode-sessions/<account>/<org>/local_<id>.json and, beside it,
/// its folder (`auditFile`) with audit.jsonl, the task's events. Only read,
/// nothing leaves this Mac, no sign-in. Unofficial: every field optional.
enum LocalCowork {
    struct Task {
        var chat: ClaudeAIChats.Chat
        /// Its context and latest answer, from its events.
        var context: ClaudeAIChats.Context?
        var window: Int?
        var costUSD: Double?
        /// What it asks you (AskUserQuestion), from its events: shown on the
        /// bar whichever task Desktop's window has (owner, 01.11).
        var ask: Ask?
        /// What its events gave, for debug.log: no names, no words.
        var seen = ""
    }

    /// A question open in a task: its tool call, with no answer in the
    /// events after it. Answered, a user event names the call (`tool_use_id`).
    struct Ask: Equatable {
        let id: String
        let questions: [QuestionItem]
    }

    /// The last question with no answer yet, in events oldest first.
    static func openAsk(in events: [[String: Any]]) -> Ask? {
        var answered = Set<String>()
        for event in events.reversed() {
            let content = ((event["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            switch event["type"] as? String {
            case "user":
                for part in content where part["type"] as? String == "tool_result" {
                    if let id = part["tool_use_id"] as? String { answered.insert(id) }
                }
            case "assistant":
                for part in content where part["type"] as? String == "tool_use" && part["name"] as? String == "AskUserQuestion" {
                    guard let id = part["id"] as? String, !answered.contains(id), let input = part["input"] as? [String: Any] else { continue }
                    let questions = PendingRequest.questions(in: input)
                    return questions.isEmpty ? nil : Ask(id: id, questions: questions)
                }
            default:
                break
            }
        }
        return nil
    }

    // MARK: Its row in Desktop's window

    /// What Desktop's window holds that may be a task's row: anything with
    /// a name or a link (its list's rows aren't links or buttons on every
    /// version: 71 of those and none its row, owner's Mac, 01.11).
    struct Row: Equatable {
        var role: String
        var label: String
        var path: String?
        /// It can be pressed itself; else the nearest part around it that can.
        var pressable: Bool
    }

    /// The rows to press for a task, in order: links to its very page; then
    /// those of exactly its name (Desktop 4.4212, measured 01.11: a button
    /// "<name> Unread response" with the name itself in a text inside it,
    /// and the one chat listed again under its project and in Recents) —
    /// the texts first, pressed by what holds them (its list comes before
    /// the page in the window, so a button of the page named as the task,
    /// "Retry", comes after its row; review 01.11), then buttons of the
    /// name. Pressed one at a time; its page says whether that was it
    /// (another chat of the same name: on to the next). One that merely
    /// starts the same isn't it. No name known: only its link.
    static func rowCandidates(_ rows: [Row], title: String?, page: String) -> [Int] {
        let links = rows.indices.filter { rows[$0].path == page }
        guard let title else { return links }
        let same = rows.indices.filter { rows[$0].path == nil && SessionStore.titleScore(rows[$0].label, title) == 3 }
        return links + same.filter { !rows[$0].pressable } + same.filter { rows[$0].pressable }
    }

    /// The first row to press, if any.
    static func rowToPress(_ rows: [Row], title: String?, page: String) -> Int? {
        rowCandidates(rows, title: title, page: page).first
    }

    /// What the window says of its sidebar: open (its Recents or a project's
    /// sessions are there, measured 01.11), shut (its "Show sidebar" button
    /// alone), or nothing to go by (the tree not read, another language).
    /// The View menu's "Show Sidebar" is a toggle (Desktop's own
    /// dispatchToggleSidebar; review 01.11): pressed only when shut for sure.
    enum Sidebar: Equatable { case open, shut, unknown }

    static func sidebar(_ rows: [Row]) -> Sidebar {
        if rows.contains(where: { $0.label == "Recents" || $0.label.hasPrefix("Toggle sessions for ") || $0.label.hasPrefix("More options for ") }) { return .open }
        if rows.contains(where: { $0.label == "Show sidebar" && $0.pressable }) { return .shut }
        return .unknown
    }

    static func sidebarOpen(_ rows: [Row]) -> Bool { sidebar(rows) == .open }

    /// For debug.log when no row is found: what the window holds, by role,
    /// and a few rows with the start of their names, so the next test on
    /// another Mac says where its list is. Once a minute, not a stream.
    static func rowsSample(_ rows: [Row], title: String?) -> String {
        var byRole: [String: Int] = [:]
        for row in rows { byRole[row.role, default: 0] += 1 }
        let roles = byRole.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(8)
            .map { "\($0.key.dropFirst(2)) \($0.value)" }.joined(separator: ", ")
        let alike = rows.filter { row in title.map { SessionStore.titleScore(row.label, $0) >= 1 } ?? false }.prefix(4)
        let named = rows.filter { !$0.label.isEmpty && $0.path != nil }.prefix(4)
        func one(_ r: Row) -> String {
            "\(r.role.dropFirst(2)) '\(r.label.prefix(12))'\(r.label.count > 12 ? "…" : "")\(r.path != nil ? " link" : "")\(r.pressable ? "" : " unpressable")"
        }
        let shown = (Array(alike) + Array(named)).map(one)
        return "\(rows.count) with a name or a link: \(roles); alike or linked: [\(shown.joined(separator: "; "))]"
    }

    /// The question its window shows is the one from its events: the same
    /// options, the window's with their descriptions after them or not (the
    /// window's words may be its header, not the question).
    static func sameQuestion(_ shown: [String], _ asked: [String]) -> Bool {
        QuestionItem.sameOptions(window: shown, asked: asked)
    }

    /// Desktop's own tab for Cowork, to press when its window shows a chat
    /// instead (its tasks' rows are in Cowork's list alone).
    static func coworkTab(_ rows: [Row], named names: Set<String> = coworkTabNames) -> Int? {
        let tabs = rows.indices.filter { rows[$0].pressable && rows[$0].path == nil && names.contains(rows[$0].label.lowercased()) }
        return tabs.count == 1 ? tabs[0] : nil
    }

    // Desktop's words in each of its languages (its i18n files, 4.4212, 01.11):
    // a label in English alone left a German or Japanese window with no Send (review 01.11).
    static let coworkTabNames: Set<String> = ["cowork"]
    static let codeTabNames: Set<String> = ["code", "coder", "codice", "código", "kode", "programar", "कोड", "コード", "코드"]
    private static let sendLabels: Set<String> = [
        "send", "send message",
        "senden", "nachricht senden",
        "enviar", "enviar mensaje", "enviar mensagem",
        "envoyer", "envoyer le message",
        "invia", "invia messaggio",
        "kirim", "kirim pesan",
        "भेजें", "संदेश भेजें",
        "送信", "メッセージを送信",
        "보내기", "메시지 보내기",
    ]

    /// The button that sends what's in its field.
    static func isSend(label: String?) -> Bool {
        sendLabels.contains(label?.lowercased() ?? "")
    }

    /// A page of claude.ai in its window, whatever it shows: a chat, or a page
    /// with none yet, its start (`/new`) or a tab's own (`/epitaxy`), which you
    /// can be taken from by a row (owner's Mac, 01.11: on `/new`, eight Send
    /// Nows did nothing). Not its shell, a file, nor the bare address.
    static func isPage(_ url: URL) -> Bool {
        ["claude.ai", "claude.com"].contains { url.host?.hasSuffix($0) == true } && url.pathComponents.count >= 2
    }

    /// Words go by its one window: while they're on their way to one chat
    /// another mustn't press its own row (review 01.11).
    static func windowTaken(sending: Set<String>, quiet: (String) -> Bool) -> Bool {
        sending.contains(where: quiet)
    }

    /// Not tried again for this long after its field said no this many times
    /// running: the words are written and taken out each time, and you may be
    /// typing there.
    static func refusedHold(times: Int) -> TimeInterval {
        min(300, 10 * pow(2, Double(max(0, times - 1))))
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }

    /// What the bar can't do for these tasks, and why: Settings and the tour say it.
    static let limits = "Claude Desktop has no way in from outside for tasks on this Mac or chats in its Code tab, so words go through its window, with Accessibility on: it has to be open, in the background is fine. If it shows another task, the bar presses this one's row in its list, unless you're using Desktop, the task shown asks you something or you've started typing there; then the words wait, and so does Send Now — only with Desktop closed does it open it. A screenshot can't go that way: it brings Desktop to the front. A task's questions show on the bar from its own journal, whichever task Desktop shows; the answer goes in the same way, through its row. Permissions can be answered only for the task it shows."

    /// No word from a task at work for this long: not at work any more. (It
    /// may be waiting on you: no event says so, Desktop's window does.)
    static let quiet: TimeInterval = 600

    /// A task's events, beside its file. Desktop's own rule (4.29): a folder
    /// of the file's name if there is one; newer tasks have one named after
    /// the first 8 digits of their id alone. Dispatch's has no short name.
    static func auditFile(of file: URL) -> URL {
        let full = file.deletingPathExtension()
        let name = full.lastPathComponent, fm = FileManager.default
        var isFolder: ObjCBool = false
        if !(fm.fileExists(atPath: full.path, isDirectory: &isFolder) && isFolder.boolValue),
           name.range(of: "^local_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil {
            let short = full.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst("local_".count).prefix(8)))
            if fm.fileExists(atPath: short.path, isDirectory: &isFolder), isFolder.boolValue { return short.appendingPathComponent("audit.jsonl") }
        }
        return full.appendingPathComponent("audit.jsonl")
    }

    /// The row to press for a task: a link to its very page; with none, the
    /// only one of exactly its name. Another that merely starts the same, or a
    /// second of the name, is no way to tell.
    static func onlyRow(_ rows: [(label: String, path: String?)], title: String, page: String) -> Int? {
        rowToPress(rows.map { Row(role: "AXLink", label: $0.label, path: $0.path, pressable: true) }, title: title, page: page)
    }

    /// Its window may be taken off the task it shows: that one asks nothing,
    /// and nothing's in its field (nil: can't be told).
    static func mayLeave(asking: Bool, draft: String?) -> Bool {
        !asking && draft?.allSatisfy(\.isWhitespace) == true
    }

    /// What's in a task's field, before words go in. Its window in the
    /// background shows what was sent there for 10 s more (owner's Mac, 31.10):
    /// the same words, just sent, aren't yours.
    enum Field: Equatable { case empty, late, unsent, yours }

    static func field(_ before: String, sent: (words: String, at: Date)?, unsent: String? = nil, now: Date = Date()) -> Field {
        func bare(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        if bare(before).isEmpty { return .empty }
        if let unsent, bare(before) == bare(unsent) { return .unsent }
        if let sent, bare(before) == bare(sent.words), now.timeIntervalSince(sent.at) < 30 { return .late }
        return .yours
    }

    /// A task, from its file and the end of its events (oldest first).
    /// Dispatch's own session isn't one of them, nor one Desktop keeps off its list.
    static func task(file: Any?, events: [[String: Any]], changed: Date, now: Date = Date()) -> Task? {
        guard let o = file as? [String: Any], let id = o["sessionId"] as? String,
              DesktopSessions.isLocal(id), !id.hasPrefix("local_ditto"), o["sessionType"] as? String != "radar" else { return nil }
        var chat = ClaudeAIChats.Chat(uuid: id)
        chat.local = true
        let first = (o["initialMessage"] as? String)?.split(separator: "\n").first.map(String.init)
        chat.name = ((o["title"] as? String) ?? first).map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        chat.model = (o["model"] as? String).map { String($0.prefix(80)) }
        chat.archived = o["isArchived"] as? Bool == true
        let active = (o["lastActivityAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        chat.updatedAt = max(active ?? .distantPast, changed)

        // What came after the last turn ended: the turn at work.
        let end = events.lastIndex { $0["type"] as? String == "result" }
        let after = events[(end.map { $0 + 1 } ?? 0)...].filter { ["user", "assistant"].contains($0["type"] as? String) }
        let result = end.map { events[$0] }
        chat.settledAt = ClaudeAIChats.date(result?["timestamp"])
        // A question with no answer in its events waits on you however long
        // (review 01.11: it doesn't run out with the clock); not an archived
        // task's, which Desktop keeps off its list.
        let ask = chat.archived ? nil : openAsk(in: Array(after))
        // A tool at work or a question on you says nothing for as long as it takes.
        let waiting = ((after.last?["message"] as? [String: Any])?["content"] as? [Any])?
            .contains { ($0 as? [String: Any])?["type"] as? String == "tool_use" } == true
        if !after.isEmpty, ask != nil || now.timeIntervalSince(changed) < (waiting ? ClaudeAIChats.recent : quiet) {
            chat.running = true
            chat.runningSince = ClaudeAIChats.date(after.first?["timestamp"])
            // Asked you something, in whichever task the window shows. No event says "may I".
            let asks = ((after.last?["message"] as? [String: Any])?["content"] as? [Any])?
                .contains { ($0 as? [String: Any])?["name"] as? String == "AskUserQuestion" } == true
            if asks || ask != nil { chat.needsInput = "question" }
        }
        var task = Task(chat: chat)
        task.ask = ask
        task.context = ClaudeAIChats.context(events: Array(events.reversed()))
        if let context = task.context, chat.model == nil { task.chat.model = context.model }
        let usage = (result?["modelUsage"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        task.window = usage.compactMap { ($0["contextWindow"] as? NSNumber)?.intValue }.max().flatMap { $0 > 0 ? $0 : nil }
        task.costUSD = (result?["total_cost_usd"] as? NSNumber)?.doubleValue
        task.seen = "\(id.dropFirst("local_".count).prefix(8)): events \(events.isEmpty ? "none" : "read"), context \(task.context != nil), window \(task.window != nil), cost \(task.costUSD != nil), answer \(task.context?.answer != nil)"
            + (task.ask.map { ", asks (\($0.questions.count) question(s))" } ?? "")
        return task
    }

    /// The events in the end of a file; a first line cut short is left out.
    static func events(tail: Data, cut: Bool) -> [[String: Any]] {
        var lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if cut, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    /// Reads what changed, off the main thread. Used from one queue at a time.
    final class Reader {
        private var kept: [String: (changed: Date, task: Task?)] = [:]
        /// The end of its events; more if a single line is longer than that.
        private let tailSizes: [UInt64] = [512 * 1024, 8 * 1024 * 1024]

        /// The tasks active in the last half hour — and those in `keep` (ids,
        /// "local_…") however long ago: words or a question wait on them, and
        /// without their file they'd have no name and no page (owner's Mac,
        /// 01.11: "Cowork" every 15 s, its row never looked for).
        func read(in folder: URL = LocalCowork.folder, now: Date = Date(), keep: Set<String> = []) -> [Task] {
            let fm = FileManager.default
            var found: [Task] = []
            var seen = Set<String>()
            for account in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                    let places = [org, org.appendingPathComponent("agent")]
                    for file in places.flatMap({ (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] })
                    where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                        let audit = LocalCowork.auditFile(of: file)
                        let changed = [file, audit].compactMap { Self.modified($0) }.max() ?? .distantPast
                        guard now.timeIntervalSince(changed) < ClaudeAIChats.recent || keep.contains(file.deletingPathExtension().lastPathComponent) else { continue }
                        seen.insert(file.path)
                        // A quiet one is looked at again too: "at work" runs out by the clock.
                        if let known = kept[file.path], known.changed == changed, known.task?.chat.running != true {
                            if let task = known.task { found.append(task) }
                            continue
                        }
                        let task = read(file: file, audit: audit, changed: changed, now: now)
                        kept[file.path] = (changed, task)
                        if let task { found.append(task) }
                    }
                }
            }
            kept = kept.filter { seen.contains($0.key) }
            return found
        }

        private func read(file: URL, audit: URL, changed: Date, now: Date) -> Task? {
            guard let data = try? Data(contentsOf: file), data.count < 8_000_000 else { return nil }
            var events: [[String: Any]] = []
            if let handle = try? FileHandle(forReadingFrom: audit) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                for tailSize in tailSizes where events.isEmpty {
                    let start = size > tailSize ? size - tailSize : 0
                    try? handle.seek(toOffset: start)
                    if let tail = try? handle.readToEnd() { events = LocalCowork.events(tail: tail, cut: start > 0) }
                }
            }
            return LocalCowork.task(file: try? JSONSerialization.jsonObject(with: data), events: events, changed: changed, now: now)
        }

        private static func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }
}
