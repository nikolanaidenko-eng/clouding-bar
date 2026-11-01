import AppKit

// The Touch Bar's blocks sharing its width, the model that says when it's
// rebuilt, and AppModel's words and order.

func runBarChecks() {
    // MARK: Room

    let gap: CGFloat = 6
    check(BarLayout.need([], gap: gap) == 0 && BarLayout.need([.fixed(100)], gap: gap) == 100, "bar need: no gap around one")
    check(BarLayout.need([.fixed(100), .shrinkable(50), .shrinkable(200), .flex(weight: 1, min: 80)], gap: gap) == 100 + 50 + 72 + 80 + 18,
          "bar need: shrinkable at 72 at the most, flexible at its least, a gap between each")

    let three: [(width: BarLayout.Width, droppable: Bool)] = [(.fixed(100), false), (.shrinkable(100), true), (.shrinkable(100), true)]
    check(BarLayout.shown(three, available: 500, gap: gap) == [0, 1, 2], "bar: all stay while they fit")
    check(BarLayout.shown(three, available: 256, gap: gap) == [0, 1, 2], "bar: shrunk they fit: all stay")
    check(BarLayout.shown(three, available: 255, gap: gap) == [0, 1], "bar: a point short: the rightmost goes")
    check(BarLayout.shown(three, available: 100, gap: gap) == [0], "bar: droppable ones go until it fits")
    check(BarLayout.shown(three, available: 50, gap: gap) == [0], "bar: what can't be dropped stays, fits or not")
    let middle: [(width: BarLayout.Width, droppable: Bool)] = [(.fixed(100), true), (.fixed(100), false), (.fixed(100), true)]
    check(BarLayout.shown(middle, available: 206, gap: gap) == [0, 1], "bar: from the right, whatever's between")
    check(BarLayout.shown(middle, available: 100, gap: gap) == [1], "bar: the undroppable one outlasts them")

    func widths(_ list: [BarLayout.Width], _ available: CGFloat, gap g: CGFloat = 6) -> [CGFloat] { BarLayout.widths(list, available: available, gap: g) }
    check(widths([.fixed(100), .flex(weight: 1, min: 50), .flex(weight: 3, min: 50)], 506) == [100, 123.5, 270.5], "bar widths: the room left, by weight, over each one's least")
    check(widths([.fixed(100), .flex(weight: 1, min: 100)], 156) == [100, 50], "bar widths: too little: flexible ones squeezed under their least")
    check(widths([.shrinkable(100), .shrinkable(300), .fixed(50)], 300, gap: 0) == [100, 150, 50], "bar widths: shrinkable ones give way, the narrow one keeps all it has")
    check(widths([.fixed(100), .fixed(100)], 150) == [100, 100], "bar widths: fixed stays fixed, no room or not")
    check(widths([.flex(weight: 0, min: 40)], 100) == [0], "bar widths: a flexible one of no weight gets nothing")
    check(widths([], 100) == [], "bar widths: nothing to place")
    check(BarLayout.overflow([.fixed(100), .flex(weight: 1, min: 50)], available: 156, gap: gap) == 0
          && BarLayout.overflow([.fixed(100), .flex(weight: 1, min: 50)], available: 155, gap: gap) == 1
          && BarLayout.overflow([.shrinkable(100)], available: 500, gap: gap) == -400, "bar overflow: its own sizes against the width")

    // Whatever comes, once `shown` has left what fits: on the bar, never less than nothing.
    do {
        let kinds: [BarLayout.Width] = [.fixed(40), .fixed(90), .shrinkable(30), .shrinkable(72), .shrinkable(160), .shrinkable(400),
                                        .flex(weight: 1, min: 80), .flex(weight: 1.2, min: 150)]
        var onBar = true, positive = true, fills = true
        for a in kinds { for b in kinds { for c in kinds { for d in kinds {
            let list = [a, b, c, d]
            for available in [120, 300, 628 - 8, 1004 - 8] as [CGFloat] where BarLayout.need(list, gap: gap) <= available {
                let w = BarLayout.widths(list, available: available, gap: gap)
                let total = w.reduce(0, +) + gap * 3
                if total > available + 0.001 { onBar = false }
                if w.contains(where: { $0 < 0 }) { positive = false }
                // Flexible ones take all there is.
                if list.contains(where: { if case .flex = $0 { return true }; return false }), abs(total - available) > 0.001 { fills = false }
            }
        } } } }
        check(onBar, "bar widths: all of it on the bar, in every combination that fits")
        check(positive, "bar widths: no block ever narrower than nothing")
        check(fills, "bar widths: a flexible block uses up what's left")
    }

    check(BarLayout.fitWidths([50, 60], total: 200) == [50, 60], "fit: room for all: as they are")
    check(BarLayout.fitWidths([50, 60], total: 110) == [50, 60], "fit: exactly the room: as they are")
    check(BarLayout.fitWidths([100, 300], total: 250) == [100, 150], "fit: the narrowest keep theirs, the rest share")
    check(BarLayout.fitWidths([300, 100], total: 250) == [150, 100], "fit: by width, not by place")
    check(BarLayout.fitWidths([80, 80, 80], total: 100) == [72, 72, 72], "fit: never under the floor, though that's too much")
    check(BarLayout.fitWidths([50, 300], total: 100) == [50, 72], "fit: one under the floor keeps its own width")
    check(BarLayout.fitWidths([100, 100], total: 0) == [72, 72], "fit: nothing to share: the floor")
    check(BarLayout.fitWidths([100, 200, 300], total: 300, floor: 10) == [100, 100, 100], "fit: another floor")
    check(BarLayout.fitWidths([], total: 10) == [], "fit: nothing to fit")
    do {
        var sums = true, keepsOwn = true
        let sets: [[CGFloat]] = [[30, 500, 90], [72, 72, 72, 72], [10, 20, 30, 40, 900], [200, 200], [71, 73, 150, 800]]
        for set in sets {
            for total in stride(from: CGFloat(0), through: 1200, by: 37) {
                let out = BarLayout.fitWidths(set, total: total)
                let least = set.map { min($0, 72) }.reduce(0, +)
                if total >= least, out.reduce(0, +) > total + 0.001, set.reduce(0, +) > total { sums = false }
                for (a, b) in zip(out, set) where a > b + 0.001 { keepsOwn = false }
            }
        }
        check(sums, "fit: within the total whenever the floor lets it")
        check(keepsOwn, "fit: never wider than it was")
    }

    // MARK: Your arrangement

    let placed = BarLayout.places(["a", "b", "c", "d"], order: ["c", "a"])
    let sortedKeys = zip(["a", "b", "c", "d"], placed).sorted { $0.1 < $1.1 }.map(\.0)
    check(sortedKeys == ["c", "d", "a", "b"], "bar order: yours; a new block right after the one before it")
    let unknown = BarLayout.places(["x", "y", "a"], order: ["a"])
    check(unknown[0] < unknown[1] && unknown[1] < unknown[2], "bar order: new ones before anything known stay first, in their own order")
    check(BarLayout.places(["a"], order: ["a", "a"]) == [0], "bar order: a name twice in your order: its first place")
    check(BarLayout.places([], order: ["a"]).isEmpty && BarLayout.places(["a", "b"], order: []).count == 2, "bar order: nothing to place, or no order yet")

    let order = ["a", "b", "c"]
    let middles: [String: CGFloat] = ["a": 10, "b": 20, "c": 30]
    check(BarLayout.moved("a", to: 25, order: order, middles: middles) == ["b", "a", "c"], "bar move: past the next one's middle")
    check(BarLayout.moved("a", to: 19, order: order, middles: middles) == ["a", "b", "c"], "bar move: not yet")
    check(BarLayout.moved("a", to: 99, order: order, middles: middles) == ["b", "c", "a"], "bar move: to the end")
    check(BarLayout.moved("c", to: 0, order: order, middles: middles) == ["c", "a", "b"], "bar move: to the start")
    check(BarLayout.moved("z", to: 15, order: order, middles: middles) == ["a", "z", "b", "c"], "bar move: one not in the order goes in")

    check(BarLayout.pulled(width: 100, by: 50.7, barWidth: 1004, widest: nil) == 150, "bar pull: whole points")
    check(BarLayout.pulled(width: 100, by: -90, barWidth: 1004, widest: nil) == 24, "bar pull: 24 at the least")
    check(BarLayout.pulled(width: 100, by: 500, barWidth: 1004, widest: 120) == 120, "bar pull: an invisible wall where something would leave the bar")
    check(BarLayout.pulled(width: 100, by: 5000, barWidth: 200, widest: nil) == 80, "bar pull: Cloud and Whole bar stay on it")
    check(BarLayout.pulled(width: 100, by: 500, barWidth: 1004, widest: 10) == 24, "bar pull: no room at all: still 24")

    // MARK: The short bar

    let shortRoom: CGFloat = 628 - 8 - 44 - 36
    check(BarLayout.shortWidth("meters", shows: ["session", "context"]) == 180 && BarLayout.shortWidth("meters", shows: ["session"]) == 90
          && BarLayout.shortWidth("chat", shows: []) == BarLayout.shortChatMin && BarLayout.shortWidth("nonsense", shows: []) == 0,
          "short bar: each block's size")
    check(BarLayout.shortFits([], room: shortRoom, gap: 6), "short bar: nothing on it fits")
    check(!BarLayout.shortFits(["name", "session", "context", "reset", "model", "agents", "lines", "branch", "cost", "chat", "templates", "shot", "mic"], room: shortRoom, gap: 6),
          "short bar: all of it doesn't")
    check(BarLayout.shortFits(["session", "context", "model", "chat"], room: 434, gap: 6) && !BarLayout.shortFits(["session", "context", "model", "chat"], room: 433, gap: 6),
          "short bar: to the point, a gap after Cloud and after each block")
    check(BarLayout.shortFits(["session", "context"], room: 198, gap: 6) && !BarLayout.shortFits(["session", "context"], room: 197, gap: 6),
          "short bar: no chat line: one more gap, for the spacer in its place")
    check(BarLayout.shortFits(["context"], room: 108, gap: 6) && !BarLayout.shortFits(["context"], room: 107, gap: 6), "short bar: one meter is half the width")

    // MARK: When it's rebuilt

    let spec = ButtonSpec(label: "go", type: .command, value: "/go")
    var base = BarModel()
    base.buttons = [spec]
    func same(_ edit: (inout BarModel) -> Void) -> Bool {
        var m = base
        edit(&m)
        return BarModel.structureKey(m) == BarModel.structureKey(base)
    }
    check(same { $0.sessionPercent = 42; $0.contextPercent = 7; $0.resetCountdown = "1:00"; $0.activity = .work; $0.awake = true },
          "bar: numbers change in place: no rebuild")
    check(!same { $0.buttons = [spec, spec] }, "bar: a button more: rebuilt")
    check(!same { $0.buttons = [ButtonSpec(label: "gone", type: .command, value: "/go")] }, "bar: a button's name: rebuilt")
    check(!same { $0.shows = ["session"] }, "bar: what shows: rebuilt")
    check(!same { $0.quiet = true }, "bar: quiet: rebuilt, nothing pulses")
    check(!same { $0.modelLabel = "Opus" } && !same { $0.short = true } && !same { $0.expanded = true } && !same { $0.order = ["a"] } && !same { $0.widths = ["a": 90] },
          "bar: the model, the short bar, your arrangement: rebuilt")
    check(!same { $0.agents = ["Explore"] } && !same { $0.branch = "main" } && !same { $0.templates = ["x"] }, "bar: subagents, branch, templates: rebuilt")
    var typing = base
    typing.mode = .typing(text: "a")
    let typed = BarModel.structureKey(typing)
    typing.mode = .typing(text: "ab")
    check(BarModel.structureKey(typing) == typed, "bar: writing a letter: the field stays, no rebuild (the cursor would be lost)")
    typing.listening = true
    check(BarModel.structureKey(typing) != typed, "bar: dictating lights the mic: rebuilt")
    var asked = base
    asked.mode = .question(text: "A long question?", options: ["Yes"], multiSelect: false, picked: [])
    asked.questionKey = "A long question?"
    let question = BarModel.structureKey(asked)
    asked.mode = .question(text: "Short?", options: ["Yes"], multiSelect: false, picked: [])
    check(BarModel.structureKey(asked) == question, "bar: a question's short form swaps in place")
    asked.mode = .question(text: "Short?", options: ["Yes"], multiSelect: false, picked: [0])
    check(BarModel.structureKey(asked) != question, "bar: an option picked: rebuilt")
    var modes: [BarModel.Mode] = [.normal, .contextWarning, .permission(verb: "Run", detail: "ls"), .typing(text: ""), .models, .agents, .chats, .templates]
    modes.append(.done(.init(id: "a", name: "A", color: 0, current: false, waiting: false)))
    let keys = modes.map { mode -> String in var m = base; m.mode = mode; return BarModel.structureKey(m) }
    check(Set(keys).count == keys.count, "bar: every mode its own")
    var two = BarModel()
    let chat = { (id: String, current: Bool) in BarModel.Chat(id: id, name: id, color: 0, current: current, waiting: false) }
    two.chats = [chat("a", true)]
    check(two.current == nil, "bar: one chat, nothing says which")
    two.chats = [chat("a", false), chat("b", true)]
    check(two.current?.id == "b", "bar: several, the one it shows")
    two.chats = [chat("a", false), chat("b", false)]
    check(two.current == nil, "bar: several, none of them shown")
    var withChat = base
    withChat.chats = [chat("a", false), chat("b", true)]
    check(BarModel.structureKey(withChat) != BarModel.structureKey(base), "bar: which chat it shows: rebuilt")
}

func runModelChecks() {
    // MARK: Numbers in words

    check(AppModel.compact(0) == "0" && AppModel.compact(999) == "999", "compact: as they are under a thousand")
    check(AppModel.compact(1000) == "1.0k" && AppModel.compact(1500) == "1.5k" && AppModel.compact(999_900) == "999.9k", "compact: thousands")
    check(AppModel.compact(1_000_000) == "1.0M" && AppModel.compact(2_340_000) == "2.3M", "compact: millions")
    knownBug(AppModel.compact(999_999) == "1.0M", "compact(999_999) says \"\(AppModel.compact(999_999))\": rounded up past the thousand, under the k")
    check(AppModel.short(999) == "999" && AppModel.short(327_499) == "327k" && AppModel.short(999_999) == "999k", "short: thousands, cut")
    check(AppModel.short(1_000_000) == "1M" && AppModel.short(1_200_000) == "1.2M" && AppModel.short(2_000_000) == "2M", "short: whole millions without .0")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func ago(_ seconds: Double) -> String { AppModel.ago(now.addingTimeInterval(-seconds), now: now) }
    check(ago(0) == "just now" && ago(59) == "just now" && ago(-500) == "just now", "ago: under a minute, or a clock ahead")
    check(ago(60) == "1 min ago" && ago(3599) == "59 min ago", "ago: minutes")
    check(ago(3600) == "1 h ago" && ago(47 * 3600 + 3599) == "47 h ago", "ago: hours, up to two days")
    check(ago(48 * 3600) == "2 d ago" && ago(30 * 86400) == "30 d ago", "ago: days")
    func elapsed(_ seconds: Double) -> String { AppModel.elapsed(since: now.addingTimeInterval(-seconds), now: now) }
    check(elapsed(-5) == "0 s" && elapsed(59) == "59 s" && elapsed(60) == "1 min" && elapsed(3599) == "59 min", "elapsed: seconds, then minutes")
    check(elapsed(3600) == "1 h 0 min" && elapsed(3900) == "1 h 5 min" && elapsed(90_000) == "25 h 0 min", "elapsed: hours and minutes")
    func duration(_ seconds: Double) -> String { AppModel.duration(since: now.addingTimeInterval(-seconds), now: now) }
    check(duration(-5) == "0 min" && duration(3599) == "59 min" && duration(3600) == "1 h" && duration(7199) == "1 h", "duration: minutes, then whole hours")

    // MARK: What it says

    let model = AppModel()
    check(model.statusTitle == "Idle", "status: nothing going on")
    model.activity = .work
    check(model.statusTitle == "Working", "status: at work")
    model.activity = .wait
    check(model.statusTitle == "Needs your OK", "status: waiting")
    model.activity = .work
    model.request = AppModel.RequestCard(id: UUID(), kind: .permission, project: nil)
    check(model.statusTitle == "Needs your OK", "status: a permission over whatever it was doing")
    model.request = AppModel.RequestCard(id: UUID(), kind: .question, project: nil)
    check(model.statusTitle == "Claude asks", "status: a question")

    check(!model.voiceShown, "voice: nothing to show")
    model.listening = true
    check(model.voiceShown, "voice: while listening")
    model.listening = false
    model.dictated = ""
    check(model.voiceShown, "voice: while there's dictated text to check")

    // MARK: The pill's items

    var saved: [(String, Any)] = []
    let items = AppModel()
    items.setConfig = { saved.append(($0, $1)) }
    check(items.itemIDs.first == "focus" && items.itemIDs.contains("session") && items.itemIDs.contains("metric:git") && items.itemIDs.last == "send",
          "items: which chat first, send last")
    items.buttons = [ButtonSpec(label: "go", type: .command, value: "/go")]
    check(items.itemIDs.contains("button:go"), "items: your buttons among them")
    items.config.itemOrder = ["mic", "session"]
    check(Array(items.itemIDs.prefix(3)) == ["focus", "mic", "session"], "items: your order, the chat's name still first unless moved")
    items.config.itemOrder = ["mic", "focus"]
    check(Array(items.itemIDs.prefix(2)) == ["mic", "focus"], "items: moved, it goes where you put it")
    items.config.itemOrder = ["gone", "mic"]
    check(items.itemIDs.first == "focus" && !items.itemIDs.contains("gone") && items.itemIDs[1] == "mic", "items: a button since removed: forgotten")
    check(items.itemIDs.count == Set(items.itemIDs).count, "items: none twice")
    check(items.rank("mic") == 1 && items.rank("nothing") == .max, "items: their place")
    items.config.itemOrder = []
    let before = items.itemIDs
    items.swapItems("session", "mic")
    let swapped = saved.last?.1 as? [String]
    check(saved.last?.0 == "itemOrder" && swapped?.firstIndex(of: "session") == before.firstIndex(of: "mic")
          && swapped?.firstIndex(of: "mic") == before.firstIndex(of: "session") && swapped?.count == before.count,
          "items: dropped on another, they trade places and nothing else moves")
    let count = saved.count
    items.swapItems("mic", "mic")
    items.swapItems("mic", "nothing")
    check(saved.count == count, "items: onto itself or nothing, nothing's saved")

    // MARK: Budgets and Settings' copy

    let heights = AppModel()
    heights.config.pillHeight = 90
    check(heights.pillHeightBudget == 90, "pill height: as pulled")
    heights.config.pillHeight = 0
    heights.config.pillRows = 2
    check(heights.pillHeightBudget == PillLayout.height(rows: 2), "pill height: else from the rows set")
    heights.config.pillRows = 0
    check(heights.pillHeightBudget == PillLayout.height(rows: 1), "pill height: at least one")

    let live = AppModel()
    var liveSaved = 0
    live.setConfig = { _, _ in liveSaved += 1 }
    live.config.pillWidth = 321
    live.sessionPercent = 77
    let example = AppModel()
    example.fillExample(from: live)
    check(example.hasSession && example.config.pillWidth == 321 && example.sessionPercent == 77, "Settings' copy: your settings and your numbers")
    check(example.resetShort == "1:23" && example.sessions.count == 1 && example.sessions[0].current, "Settings' copy: an example for what's not known")
    example.setConfig("x", 1)
    check(liveSaved == 1, "Settings' copy: what you arrange there is saved through the live model")
}
