import Foundation

/// One message that arrived on the socket (docs/protocol.md). Hook events
/// carry hook_event_name; status messages (the status line, cloudingbar-tap)
/// carry rate_limits and/or context_window instead. Fields mirror Claude
/// Code's own JSON and may all be missing.
struct Inbound {
    let raw: [String: Any]

    init?(data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        raw = obj
    }

    init(raw: [String: Any]) { self.raw = raw }

    var event: String? { raw["hook_event_name"] as? String }
    var sessionId: String? { raw["session_id"] as? String }
    var cwd: String? { raw["cwd"] as? String }
    var transcriptPath: String? { raw["transcript_path"] as? String }
    var message: String? { raw["message"] as? String }
    var notificationType: String? { raw["notification_type"] as? String }
    var toolName: String? { raw["tool_name"] as? String }
    var toolInput: [String: Any] { raw["tool_input"] as? [String: Any] ?? [:] }
    var toolResponse: Any? { raw["tool_response"] }
    var toolUseId: String? { raw["tool_use_id"] as? String }
    /// Set when the hook fired inside a subagent (and on SubagentStart/Stop).
    var agentId: String? { raw["agent_id"] as? String }
    var agentType: String? { raw["agent_type"] as? String }
    var permissionSuggestions: [Any]? { raw["permission_suggestions"] as? [Any] }
    /// Stop's: the text of Claude's final answer in the turn (cut to
    /// AnswerPreview.kept). On StopFailure it's the error, not an answer.
    var lastAssistantMessage: String? {
        (raw["last_assistant_message"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(AnswerPreview.kept)) }
    }

    /// Added by cloudingbar-hook.
    var claudePid: Int32? { (raw["claude_pid"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.intValue) } }
    var entrypoint: String? { raw["claude_entrypoint"] as? String }
    var effort: String? { raw["claude_effort"] as? String }
    /// The branch of its folder and of the file in tool_input.
    var gitBranch: String? { raw["git_branch"] as? String }
    var fileBranch: String? { raw["file_branch"] as? String }

    /// A message the sender waits on for an answer.
    var isRequest: Bool {
        event == "PermissionRequest" || (event == "PreToolUse" && toolName == "AskUserQuestion")
    }

    // MARK: Status line / cloudingbar-tap

    var fiveHour: (used: Double?, resetsAt: Double?)? {
        guard let limits = raw["rate_limits"] as? [String: Any],
              let window = limits["five_hour"] as? [String: Any] else { return nil }
        return ((window["used_percentage"] as? NSNumber)?.doubleValue,
                (window["resets_at"] as? NSNumber)?.doubleValue)
    }

    /// The weekly (7-day) limit, on Pro and Max plans.
    var sevenDay: (used: Double?, resetsAt: Double?)? {
        guard let limits = raw["rate_limits"] as? [String: Any],
              let window = limits["seven_day"] as? [String: Any] else { return nil }
        return ((window["used_percentage"] as? NSNumber)?.doubleValue,
                (window["resets_at"] as? NSNumber)?.doubleValue)
    }

    var contextUsedPercent: Double? {
        ((raw["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue
    }

    var contextWindowSize: Int? {
        ((raw["context_window"] as? [String: Any])?["context_window_size"] as? NSNumber)?.intValue
    }

    /// The status line's model object, or Codex's hooks' plain string.
    var modelId: String? {
        if let id = (raw["model"] as? [String: Any])?["id"] as? String { return id }
        return entrypoint == "codex" ? raw["model"] as? String : nil
    }

    var costUSD: Double? {
        ((raw["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue
    }
}
