import Foundation

extension AppModel {
    /// Every item the pill and the panel can show, in the owner's order.
    var itemIDs: [String] {
        let all = ["focus", "session", "context", "reset", "cost"] + PillLayout.metricIDs.map { "metric:" + $0 } + ["chat"]
            + buttons.map { "button:" + $0.label } + ["templates", "shot", "mic", "send"]
        let order = config.itemOrder
        // Which chat it shows comes first, unless it was moved.
        func rank(_ e: (offset: Int, element: String)) -> Int {
            order.firstIndex(of: e.element) ?? (e.element == "focus" ? -1 : order.count + e.offset)
        }
        return all.enumerated().sorted { rank($0) < rank($1) }.map(\.element)
    }

    func rank(_ id: String) -> Int { itemIDs.firstIndex(of: id) ?? .max }

    /// Dropped one item onto another: they trade places, here and wherever
    /// else both show.
    func swapItems(_ a: String, _ b: String) {
        var ids = itemIDs
        guard a != b, let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: b) else { return }
        ids.swapAt(i, j)
        setConfig("itemOrder", ids)
    }
}
