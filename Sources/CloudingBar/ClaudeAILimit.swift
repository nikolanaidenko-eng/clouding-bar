import Foundation
import Security

/// Opt-in: the live 5-hour limit for the whole account (Desktop and Cowork
/// chats too), read from claude.ai with the session key you paste in.
/// The key gives full access to your account, so: kept only in the
/// Keychain, sent only to claude.ai, used only to read usage, at most once
/// a minute. The address is unofficial and may stop working.
final class ClaudeAILimit {
    var onUpdate: ((_ percent: Double, _ resetsAt: Double?) -> Void)?
    /// "On", "Key rejected…", etc., for Settings.
    var onState: ((String) -> Void)?

    private var timer: Timer?
    private var orgId: String?
    private static let service = "Clouding Bar · claude.ai session key"

    // MARK: Keychain

    static var hasKey: Bool { readKey() != nil }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        deleteKey()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "sessionKey",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(key.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }

    private static func readKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "sessionKey",
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Polling

    func start() {
        stop()
        guard Self.hasKey else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        orgId = nil
    }

    private func poll() {
        guard let key = Self.readKey() else { stop(); return }
        if let org = orgId {
            fetchUsage(org: org, key: key)
            return
        }
        get("https://claude.ai/api/organizations", key: key) { [weak self] json in
            // The first organization that can chat (a personal account has one).
            let orgs = json as? [[String: Any]] ?? []
            let chat = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") ?? false } ?? orgs.first
            guard let id = chat?["uuid"] as? String else {
                self?.onState?("No organization found for this key")
                return
            }
            self?.orgId = id
            self?.fetchUsage(org: id, key: key)
        }
    }

    private func fetchUsage(org: String, key: String) {
        get("https://claude.ai/api/organizations/\(org)/usage", key: key) { [weak self] json in
            guard let window = (json as? [String: Any])?["five_hour"] as? [String: Any],
                  let utilization = (window["utilization"] as? NSNumber)?.doubleValue else {
                self?.onState?("Unexpected answer from claude.ai")
                return
            }
            var resets: Double?
            if let s = window["resets_at"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resets = (f.date(from: s) ?? ISO8601DateFormatter().date(from: s))?.timeIntervalSince1970
            }
            self?.onUpdate?(utilization, resets)
            self?.onState?("On")
        }
    }

    /// A read-only GET to claude.ai with the session cookie.
    private func get(_ url: String, key: String, _ done: @escaping (Any?) -> Void) {
        guard let u = URL(string: url), u.host == "claude.ai" else { return }
        var request = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error != nil || status == 0 {
                    self?.onState?("Can't reach claude.ai")
                    return
                }
                if status == 401 || status == 403 {
                    self?.onState?("Key rejected or blocked (HTTP \(status)). Paste a fresh key.")
                    self?.stop()
                    return
                }
                guard status == 200, let data else {
                    self?.onState?("claude.ai answered HTTP \(status)")
                    return
                }
                done(try? JSONSerialization.jsonObject(with: data))
            }
        }.resume()
    }
}
