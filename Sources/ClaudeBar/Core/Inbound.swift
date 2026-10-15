import Foundation

/// One message that arrived on the socket (docs/protocol.md). Hook events
/// carry hook_event_name; status messages (the status line, claudebar-tap)
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
    var permissionSuggestions: [Any]? { raw["permission_suggestions"] as? [Any] }

    /// Added by claudebar-hook.
    var claudePid: Int32? { (raw["claude_pid"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.intValue) } }
    var entrypoint: String? { raw["claude_entrypoint"] as? String }

    /// A message the sender waits on for an answer.
    var isRequest: Bool {
        event == "PermissionRequest" || (event == "PreToolUse" && toolName == "AskUserQuestion")
    }

    // MARK: Status line / claudebar-tap

    var fiveHour: (used: Double?, resetsAt: Double?)? {
        guard let limits = raw["rate_limits"] as? [String: Any],
              let window = limits["five_hour"] as? [String: Any] else { return nil }
        return ((window["used_percentage"] as? NSNumber)?.doubleValue,
                (window["resets_at"] as? NSNumber)?.doubleValue)
    }

    var contextUsedPercent: Double? {
        ((raw["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue
    }

    var contextWindowSize: Int? {
        ((raw["context_window"] as? [String: Any])?["context_window_size"] as? NSNumber)?.intValue
    }

    var modelId: String? { (raw["model"] as? [String: Any])?["id"] as? String }

    var costUSD: Double? {
        ((raw["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue
    }
}
