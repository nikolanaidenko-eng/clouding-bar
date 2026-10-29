import Foundation

/// One question from AskUserQuestion.
struct QuestionItem {
    let text: String
    let options: [String]
    let descriptions: [String]
    let multiSelect: Bool
}

/// Something Claude is waiting on that the bar can answer: a permission
/// or questions (AskUserQuestion).
///
/// Questions arrive twice: first as PreToolUse, which blocks Claude while
/// the hook runs, then as PermissionRequest, which VS Code and the desktop
/// app run alongside their own dialog. So there the bar takes questions from
/// PermissionRequest and nothing waits on it; elsewhere it takes them from
/// PreToolUse and holds them only briefly (questionHoldSeconds).
final class PendingRequest {
    enum Kind { case permission, question }

    let id = UUID()
    let kind: Kind
    /// Came from PermissionRequest (else PreToolUse).
    let viaPermission: Bool
    let sessionId: String?
    let entrypoint: String?
    let toolName: String
    let toolInput: [String: Any]
    let suggestions: [Any]?
    let questions: [QuestionItem]
    let responder: Responder
    let created = Date()
    /// Asked in Claude Desktop's own window (Cowork, its chats), which no
    /// hook reaches: answered by pressing the choice there (DesktopChat).
    /// What it was, to know it again.
    let desktopKey: String?
    /// Asked in a Cowork task, as claude.ai has it (its session's
    /// pending_action): answered through claude.ai by this request id.
    let remoteKey: String?

    /// When the app stops holding it and lets Claude's own UI take over.
    var holdUntil: Date?
    /// Question progress.
    var index = 0
    var answers: [String: String] = [:]
    var picked: Set<Int> = []

    init?(_ m: Inbound, responder: Responder) {
        self.responder = responder
        desktopKey = nil
        remoteKey = nil
        sessionId = m.sessionId
        entrypoint = m.entrypoint
        toolName = m.toolName ?? "tool"
        toolInput = m.toolInput
        suggestions = m.permissionSuggestions
        viaPermission = m.event == "PermissionRequest"
        if toolName != "AskUserQuestion" {
            kind = .permission
            questions = []
        } else {
            kind = .question
            questions = Self.questions(in: toolInput)
            if questions.isEmpty { return nil }
        }
    }

    /// What a Cowork task waits on, read from claude.ai: the answer goes
    /// back there (`answered` gets what a PermissionRequest hook would print).
    init?(remote pending: ClaudeAIChats.Pending, sessionId: String, answered: @escaping ([String: Any]) -> Void) {
        responder = Responder(answered: answered)
        desktopKey = nil
        remoteKey = pending.requestId
        self.sessionId = sessionId
        entrypoint = "cowork"
        toolName = pending.tool
        toolInput = pending.input
        suggestions = nil
        viaPermission = true
        if toolName != "AskUserQuestion" {
            kind = .permission
            questions = []
        } else {
            kind = .question
            questions = Self.questions(in: toolInput)
            if questions.isEmpty { return nil }
        }
    }

    /// AskUserQuestion's questions, as its input has them.
    static func questions(in input: [String: Any]) -> [QuestionItem] {
        (input["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let raw = (q["options"] as? [[String: Any]] ?? []).filter { $0["label"] is String }
            return QuestionItem(text: text,
                                options: raw.map { $0["label"] as! String },
                                descriptions: raw.map { $0["description"] as? String ?? "" },
                                multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// A question in Claude Desktop's window: one at a time, as it shows them.
    init(desktopQuestion text: String, options: [String], multiSelect: Bool, sessionId: String?, key: String) {
        responder = Responder()
        desktopKey = key
        remoteKey = nil
        kind = .question
        viaPermission = false
        self.sessionId = sessionId
        entrypoint = "claude-desktop"
        toolName = "AskUserQuestion"
        toolInput = [:]
        suggestions = nil
        questions = [QuestionItem(text: text, options: options, descriptions: options.map { _ in "" }, multiSelect: multiSelect)]
    }

    /// A permission in Claude Desktop's window: what it asks, in its words.
    init(desktopPermission text: String, sessionId: String?, key: String) {
        responder = Responder()
        desktopKey = key
        remoteKey = nil
        kind = .permission
        viaPermission = true
        self.sessionId = sessionId
        entrypoint = "claude-desktop"
        toolName = "Allow"
        toolInput = ["detail": text]
        suggestions = nil
        questions = []
    }

    var current: QuestionItem? { index < questions.count ? questions[index] : nil }

    /// This one, read from Claude Desktop's window, is what `remote` (read
    /// from claude.ai) asks: its chat's — or, read with the app in the back
    /// and its chat unknown, the same kind, a question by its words or its
    /// choices (the window's words may be its header). The bar shows it
    /// once (review, 29.10).
    func sameAsk(as remote: PendingRequest) -> Bool {
        if let s = sessionId { return s == remote.sessionId }
        guard kind == remote.kind else { return false }
        guard kind == .question, let mine = questions.first else { return true }
        return remote.questions.contains { $0.text == mine.text || !mine.options.isEmpty && Set($0.options) == Set(mine.options) }
    }

    /// "Always" is Claude's: Codex refuses what it would remember, and
    /// claude.ai's card of a Cowork task carries no rule to remember — there
    /// it would only be a second Allow.
    var canRemember: Bool { entrypoint != "codex" && remoteKey == nil }

    /// VS Code and the desktop app show their own dialog alongside the hook
    /// and take whichever answer comes first, so holding there costs
    /// nothing; a Cowork task waits on its own. Elsewhere (terminal,
    /// scripts) Claude may wait on the hook.
    var hostAnswersInParallel: Bool {
        entrypoint == "claude-vscode" || entrypoint == "claude-desktop" || desktopKey != nil || remoteKey != nil
    }

    /// Records an answer to the current question. True when all are done.
    func answerCurrent(_ answer: String) -> Bool {
        guard let q = current else { return true }
        answers[q.text] = answer
        index += 1
        picked = []
        return index >= questions.count
    }

    // MARK: What the bar shows

    /// ("Run", "npm test"), ("Edit", "Makefile"), …
    var summary: (verb: String, detail: String) {
        func str(_ key: String) -> String? { toolInput[key] as? String }
        func file(_ key: String) -> String? { str(key).map { URL(fileURLWithPath: $0).lastPathComponent } }
        let oneLine: (String) -> String = { $0.replacingOccurrences(of: "\n", with: " ⏎ ") }
        switch toolName {
        case "apply_patch" where !patchFiles.isEmpty:
            // Codex's patch: which files, not the patch (fullDetail has the list).
            let files = patchFiles
            let names = files.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            let shown = names.count > 3 ? Array(names.prefix(2)) + ["+\(names.count - 2) more"] : names
            let verb = files.allSatisfy { $0.action == "Add" } ? "Write" : files.allSatisfy { $0.action == "Delete" } ? "Delete" : "Edit"
            return (verb, shown.joined(separator: ", "))
        case "Bash": return ("Run", oneLine(str("command") ?? ""))
        case "Edit", "MultiEdit": return ("Edit", file("file_path") ?? "")
        case "Write": return ("Write", file("file_path") ?? "")
        case "NotebookEdit": return ("Edit", file("notebook_path") ?? "")
        case "WebFetch": return ("Fetch", str("url") ?? "")
        case "WebSearch": return ("Search", str("query") ?? "")
        default:
            if toolName.hasPrefix("mcp__") {
                return ("Use", toolName.components(separatedBy: "__").dropFirst().joined(separator: " · "))
            }
            let detail = toolInput.values.compactMap { $0 as? String }.first.map(oneLine) ?? ""
            return (toolName, detail)
        }
    }

    /// What the widget's card shows, so Allow isn't pressed blind: the
    /// whole command; for an edit the file and what goes and comes; for a
    /// new file its start; for anything else (an MCP server's tool) every
    /// argument — not only the tool's name.
    var fullDetail: String {
        func str(_ key: String) -> String? { toolInput[key] as? String }
        func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
        switch toolName {
        case "apply_patch" where !patchFiles.isEmpty:
            let files = patchFiles
            return (files.prefix(12).map { $0.action + " " + $0.path } + (files.count > 12 ? ["… +\(files.count - 12) more"] : []))
                .joined(separator: "\n")
        case "Bash":
            return str("command") ?? summary.detail
        case "Edit":
            return [str("file_path"), str("old_string").map { "− " + cut($0, 400) }, str("new_string").map { "+ " + cut($0, 400) }]
                .compactMap { $0 }.joined(separator: "\n")
        case "MultiEdit":
            let n = (toolInput["edits"] as? [Any])?.count ?? 0
            return (str("file_path") ?? "") + " · \(n) change\(n == 1 ? "" : "s")"
        case "Write":
            return [str("file_path"), str("content").map { cut($0, 600) }].compactMap { $0 }.joined(separator: "\n")
        default:
            let args = toolInput.keys.sorted().map { key -> String in
                let value = toolInput[key]
                let text = (value as? String)
                    ?? ((try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed]))
                        .flatMap { String(data: $0, encoding: .utf8) }) ?? "\(value ?? "")"
                return key + ": " + cut(text, 400)
            }
            return ([summary.detail] + args).joined(separator: "\n")
        }
    }

    /// The files an apply_patch changes, from its "*** Update File: path" lines
    /// (Add, Delete too; a move shows as its new path).
    var patchFiles: [(action: String, path: String)] {
        guard let patch = (toolInput["command"] ?? toolInput["input"]) as? String else { return [] }
        return Self.patchFiles(in: patch)
    }

    static func patchFiles(in patch: String) -> [(action: String, path: String)] {
        var files: [(action: String, path: String)] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            for action in ["Update", "Add", "Delete"] where line.hasPrefix("*** \(action) File: ") {
                files.append((action, String(line.dropFirst("*** \(action) File: ".count)).trimmingCharacters(in: .whitespaces)))
            }
            if line.hasPrefix("*** Move to: "), !files.isEmpty {
                files[files.count - 1].path = String(line.dropFirst("*** Move to: ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return files
    }

    // MARK: Hook output (docs: code.claude.com/docs/en/hooks)

    static func allow() -> [String: Any] {
        permissionOutput(["behavior": "allow"])
    }

    /// Allow, and remember it the way Claude itself suggested. Without a
    /// suggestion it's a plain allow.
    func always() -> [String: Any] {
        // Codex refuses updatedPermissions (it fails closed): a plain allow there.
        guard entrypoint != "codex", let suggestions, !suggestions.isEmpty else { return Self.allow() }
        return Self.permissionOutput(["behavior": "allow", "updatedPermissions": suggestions])
    }

    static func deny() -> [String: Any] {
        permissionOutput(["behavior": "deny", "message": "Denied from the Touch Bar."])
    }

    private static func permissionOutput(_ decision: [String: Any]) -> [String: Any] {
        ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }

    /// The questions with our answers filled in.
    func answerOutput() -> [String: Any] {
        var input = toolInput
        input["answers"] = answers
        if viaPermission {
            return Self.permissionOutput(["behavior": "allow", "updatedInput": input])
        }
        return ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": input,
        ]]
    }
}
