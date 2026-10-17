import Foundation

/// The 5-hour limit over time, for the Stats tab: one line per change in
/// ~/.cloudingbar/limit-history.jsonl ({"t": unix seconds, "p": percent}),
/// plus the snapshots Claude Desktop keeps in plan-usage-history.json.
enum LimitHistory {
    struct Sample { let time: Date; let percent: Double }

    private static var fileURL: URL { Config.directory.appendingPathComponent("limit-history.jsonl") }
    private static var last: (percent: Double, time: Date)?

    /// Records a reading: on any change, else at most every 10 minutes.
    static func record(_ percent: Double, now: Date = Date()) {
        if let last, abs(last.percent - percent) < 0.5, now.timeIntervalSince(last.time) < 600 { return }
        last = (percent, now)
        let line = "{\"t\":\(Int(now.timeIntervalSince1970)),\"p\":\(Int(percent.rounded()))}\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func load(since: Date) -> [Sample] {
        var samples: [Sample] = []
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let t = (o["t"] as? NSNumber)?.doubleValue, let p = (o["p"] as? NSNumber)?.doubleValue else { continue }
                let d = Date(timeIntervalSince1970: t)
                if d >= since { samples.append(Sample(time: d, percent: p)) }
            }
        }
        // Claude Desktop's own snapshots: {"samples":[{"t": ms, "u": {"fh": 5h %, "sd": 7d %}}]}
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        if let data = try? Data(contentsOf: desktop),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let list = o["samples"] as? [[String: Any]] {
            for s in list {
                guard let t = (s["t"] as? NSNumber)?.doubleValue,
                      let fh = ((s["u"] as? [String: Any])?["fh"] as? NSNumber)?.doubleValue else { continue }
                let d = Date(timeIntervalSince1970: t / 1000)
                if d >= since { samples.append(Sample(time: d, percent: fh)) }
            }
        }
        return samples.sorted { $0.time < $1.time }
    }
}
