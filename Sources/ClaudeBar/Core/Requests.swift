import Foundation

/// One question from AskUserQuestion.
struct QuestionItem {
    let text: String
    let options: [String]
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

    /// When the app stops holding it and lets Claude's own UI take over.
    var holdUntil: Date?
    /// Question progress.
    var index = 0
    var answers: [String: String] = [:]
    var picked: Set<Int> = []

    init?(_ m: Inbound, responder: Responder) {
        self.responder = responder
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
            let list = toolInput["questions"] as? [[String: Any]] ?? []
            questions = list.compactMap { q in
                guard let text = q["question"] as? String else { return nil }
                let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                return QuestionItem(text: text, options: options, multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            if questions.isEmpty { return nil }
        }
    }

    var current: QuestionItem? { index < questions.count ? questions[index] : nil }

    /// VS Code and the desktop app show their own dialog alongside the hook
    /// and take whichever answer comes first, so holding there costs
    /// nothing. Elsewhere (terminal, scripts) Claude may wait on the hook.
    var hostAnswersInParallel: Bool {
        entrypoint == "claude-vscode" || entrypoint == "claude-desktop"
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

    // MARK: Hook output (docs: code.claude.com/docs/en/hooks)

    static func allow() -> [String: Any] {
        permissionOutput(["behavior": "allow"])
    }

    /// Allow, and remember it the way Claude itself suggested. Without a
    /// suggestion it's a plain allow.
    func always() -> [String: Any] {
        guard let suggestions, !suggestions.isEmpty else { return Self.allow() }
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
