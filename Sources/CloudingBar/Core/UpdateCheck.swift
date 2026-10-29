import Foundation

/// Which release is the newest, from GitHub's list of the repository's
/// releases: the part of the update check that needs no network
/// (Updater.swift asks GitHub and installs).
enum UpdateCheck {
    struct Release: Equatable {
        let version: String
        let dmg: URL
        let page: URL?
    }

    static let repo = "wvnikola/clouding-bar"

    /// GitHub's list of releases, newest first (CLOUDINGBAR_UPDATE_FEED
    /// stands in for it in tests).
    static var feed: URL {
        ProcessInfo.processInfo.environment["CLOUDINGBAR_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
    }

    /// The newest Mac release: published (not a draft or a pre-release), with
    /// a Clouding-Bar-<x.y.z>.dmg. Windows releases carry none.
    static func newest(in data: Data) -> Release? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var best: Release?
        for release in list where release["draft"] as? Bool != true && release["prerelease"] as? Bool != true {
            for asset in release["assets"] as? [[String: Any]] ?? [] {
                guard let name = asset["name"] as? String, let version = version(ofDMG: name),
                      let link = asset["browser_download_url"] as? String, let dmg = URL(string: link) else { continue }
                if best.map({ isNewer(version, than: $0.version) }) ?? true {
                    best = Release(version: version, dmg: dmg, page: (release["html_url"] as? String).flatMap(URL.init(string:)))
                }
            }
        }
        return best
    }

    /// "Clouding-Bar-1.2.3.dmg" → "1.2.3"; anything else, nil.
    static func version(ofDMG name: String) -> String? {
        let prefix = "Clouding-Bar-", suffix = ".dmg"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let version = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return version
    }

    /// 1.10.0 is newer than 1.9.3: number by number, not as text.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Time for the daily check: a day since the last one (a few hours'
    /// slack, so it doesn't drift later every day).
    static func due(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= 20 * 3600
    }
}
