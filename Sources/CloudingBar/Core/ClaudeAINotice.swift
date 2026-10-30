import Foundation

/// What the app says about signing in to claude.ai (owner, 30.10). Anthropic's
/// terms don't allow a third-party app to keep claude.ai session keys or to
/// reach claude.ai automatically, and Anthropic hasn't approved this app: the
/// same words in the sign-in window (before anything is loaded or taken), in
/// the one-time question to those who signed in before 1.2.21, and, shorter,
/// in Settings, the tour and the docs.
enum ClaudeAINotice {
    /// Anthropic's written rules, for the docs.
    static let rules = "https://code.claude.com/docs/en/legal-and-compliance"

    static let title = "Signing in to claude.ai goes against Anthropic's terms"

    /// What stops without the sign-in, checked against the code (30.10): the
    /// list of Cowork tasks and claude.ai chats, the account-wide limit
    /// (Claude Code's own 5-hour limit comes from its status line, no key),
    /// and words sent through Remote Control — to a Claude Desktop or
    /// Terminal chat without its window in front. Cowork's questions read
    /// from Claude Desktop's window, Claude Code, Codex, Stats of Claude Code
    /// need none.
    static let text = """
        Anthropic's terms don't allow third-party apps to collect or store claude.ai session keys, or to reach claude.ai automatically. \
        Signing in here goes against them and could put your account at risk, including suspension. \
        Anthropic hasn't approved Clouding Bar.

        Without this sign-in everything else keeps working, except Cowork tasks, claude.ai chats, the account-wide limit \
        and sending to a Claude Desktop or Terminal chat through Remote Control without switching windows.

        Use it at your own risk.
        """

    /// One line, for a settings row and the tour.
    static let short = "Against Anthropic's terms for third-party apps: could put your account at risk. Use at your own risk."

    /// The question at launch: only for a key already in the Keychain, and
    /// only once. Nobody without a key sees it.
    static func needsAsk(hasKey: Bool, shown: Bool) -> Bool { hasKey && !shown }
}
