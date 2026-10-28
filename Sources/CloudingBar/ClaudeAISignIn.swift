import AppKit
import WebKit

/// Settings → Connections → claude.ai → Sign In…: claude.ai's own sign-in
/// page in a window of ours, with a browser store of its own that nothing
/// keeps. Once you're signed in, the session key is taken from the page's
/// cookie, handed on for the Keychain, and the window closes — no key to
/// find and paste (owner, 28.10).
final class ClaudeAISignIn: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    /// Windows the page opened (a Google or Apple sign-in), closed with it.
    private var popups: [NSWindow] = []
    private var done: ((String?) -> Void)?
    private var taken = false

    /// Shows the window (or brings it up); `done` gets the key, or nil when
    /// the window was closed without one.
    func show(done: @escaping (String?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.done = done
        taken = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        // As Safari: some sign-ins (Google) turn away an app's web view.
        web.customUserAgent = Self.safariAgent
        config.websiteDataStore.httpCookieStore.add(self)
        webView = web

        let note = NSTextField(wrappingLabelWithString:
            "Sign in to claude.ai as you always do. Clouding Bar then keeps your session key in the Keychain and closes this window. "
            + "The key opens your whole account: it's sent only to claude.ai, only to read your limit and your chats. "
            + "Unofficial — it can stop working any time.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [note, web])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        note.translatesAutoresizingMaskIntoConstraints = false
        web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            web.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Sign In to claude.ai"
        w.contentView = stack
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        DebugLog.note("claude.ai sign-in: window open")
    }

    /// "Mozilla/5.0 … Version/27.0 Safari/605.1.15", this Mac's Safari.
    private static var safariAgent: String {
        let plist = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = plist?["CFBundleShortVersionString"] as? String ?? "18.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }

    // MARK: The key

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { look(in: cookieStore) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        look(in: webView.configuration.websiteDataStore.httpCookieStore)
    }

    private func look(in store: WKHTTPCookieStore) {
        store.getAllCookies { [weak self] cookies in
            guard let self, !self.taken,
                  let cookie = cookies.first(where: { $0.name == "sessionKey" && Self.isClaudeAI($0.domain) }),
                  !cookie.value.isEmpty else { return }
            self.taken = true
            DebugLog.note("claude.ai sign-in: signed in, key taken")
            self.done?(cookie.value)
            self.done = nil
            self.window?.close()
        }
    }

    private static func isClaudeAI(_ domain: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return d == "claude.ai"
    }

    // MARK: The page

    /// Only web pages: not the Claude app's own links (claude://) or any
    /// other app's.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == "https" || scheme == "about" || scheme == "blob" ? .allow : .cancel)
    }

    /// A sign-in that opens a window of its own gets one, sharing the page's store.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        child.customUserAgent = Self.safariAgent
        let w = NSWindow(contentRect: child.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign In"
        w.contentView = child
        w.isReleasedWhenClosed = false
        if let parent = window { w.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 40, y: parent.frame.maxY - 40)) }
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let w = popups.first(where: { $0.contentView === webView }) {
            w.close()
            popups.removeAll { $0 === w }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        webView?.configuration.websiteDataStore.httpCookieStore.remove(self)
        webView?.stopLoading()
        for w in popups { w.close() }
        popups = []
        webView = nil
        window = nil
        if !taken { DebugLog.note("claude.ai sign-in: closed without signing in") }
        done?(nil)
        done = nil
    }
}
