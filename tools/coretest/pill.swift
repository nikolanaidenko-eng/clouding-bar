import Foundation

// The pill's arithmetic and the widget's rules: plain widths in, places out.

private typealias Item = (part: PillLayout.Part, width: CGFloat, id: String)

private func item(_ part: PillLayout.Part, _ width: CGFloat, _ id: String) -> Item { (part, width, id) }

/// The pill with most of what it can show.
private let fullParts: [Item] = PillLayout.ordered([
    item(.focus, 70, "focus"), item(.session, 34, "session"), item(.context, 60, "context"),
    item(.reset, 50, "reset"), item(.cost, 44, "cost"), item(.metric("model"), 120, "metric:model"),
    item(.metric("lines"), 70, "metric:lines"), item(.chat, 200, "chat"), item(.button(0), 60, "button:a"),
    item(.templates, 26, "templates"), item(.shot, 26, "shot"), item(.mic, 26, "mic"),
], by: [])

private func layout(_ parts: [Item], widths: [String: Double] = [:], chat: CGSize = CGSize(width: 90, height: 60)) -> PillLayout {
    PillLayout(parts: parts, widths: widths, chatSize: chat)
}

func runPillChecks() {
    // MARK: What order it shows

    func ids(_ list: [Item]) -> [String] { list.map(\.id) }
    let numbers = [item(.session, 10, "session"), item(.context, 20, "context"), item(.reset, 5, "reset"),
                   item(.metric("git"), 30, "metric:git"), item(.mic, 26, "mic")]
    check(ids(PillLayout.ordered(numbers, by: ["mic", "session", "context", "reset", "metric:git"]))
            == ["mic", "session", "context", "reset", "sessionBar", "contextBar", "metric:git"],
          "pill order: yours; the bars right after the last number")
    check(ids(PillLayout.ordered([item(.context, 1, "context"), item(.reset, 1, "reset"), item(.mic, 1, "mic")], by: []))
            == ["context", "reset", "contextBar", "mic"], "pill order: the session hidden, its bar goes too")
    check(ids(PillLayout.ordered([item(.session, 1, "session"), item(.mic, 1, "mic")], by: []))
            == ["session", "sessionBar", "mic"], "pill order: no context, no context bar")
    check(ids(PillLayout.ordered([item(.mic, 1, "mic")], by: [])) == ["mic"], "pill order: no numbers, no bars")
    check(ids(PillLayout.ordered([item(.session, 1, "session"), item(.metric("git"), 1, "metric:git"), item(.context, 1, "context")],
                                 by: ["session", "metric:git", "context"])) == ["session", "metric:git", "context", "sessionBar", "contextBar"],
          "pill order: a metric between the numbers stays between, the bars still after the last")
    check(ids(PillLayout.ordered([item(.mic, 1, "mic"), item(.shot, 1, "shot"), item(.cost, 1, "cost")], by: ["cost"]))
            == ["cost", "mic", "shot"], "pill order: what isn't in your order keeps its own, after what is")

    // MARK: Rows

    let two = PillLayout.flow([50, 50], width: 200)
    check(two.rows == [[0, 1]] && two.widths == [158], "pill flow: both on a row, after the character")
    let wrapped = PillLayout.flow([50, 50], width: 150)
    check(wrapped.rows == [[0], [1]] && wrapped.widths == [94, 94], "pill flow: the second one wraps, its row lines up under the first")
    let edge = PillLayout.flow([50, 50], width: 158 + PillLayout.pad)
    check(edge.rows == [[0, 1]], "pill flow: exactly the room: it stays on the row")
    let over = PillLayout.flow([50, 50], width: 157.5 + PillLayout.pad)
    check(over.rows == [[0], [1]], "pill flow: half a point short: it wraps")
    let wide = PillLayout.flow([500], width: 100)
    check(wide.rows == [[0]] && wide.widths == [544], "pill flow: too wide for any row still takes one (fits says no)")
    check(PillLayout.flow([], width: 100).rows == [[]], "pill flow: nothing, one empty row")

    for rows in 1...6 {
        check(PillLayout.rows(forHeight: PillLayout.height(rows: rows)) == rows, "pill rows: \(rows) from its own height")
    }
    check(PillLayout.height(rows: 1) == 44 && PillLayout.height(rows: 0) == 44 && PillLayout.height(rows: -3) == 44, "pill height: at least a row")
    check(PillLayout.rows(forHeight: 0) == 1 && PillLayout.rows(forHeight: -20) == 1, "pill rows: at least one, whatever's asked")
    check(PillLayout.rows(forHeight: 78 - 6) == 2 && PillLayout.rows(forHeight: 78 - 7) == 1, "pill rows: within 6 pt of a row counts as that row")

    check(PillLayout.isVertical(width: 44, height: 45) && !PillLayout.isVertical(width: 44, height: 44)
          && !PillLayout.isVertical(width: 200, height: 200) && PillLayout.isVertical(width: 200, height: 201)
          && !PillLayout.isVertical(width: 10, height: 44), "pill: a column only once taller than wide and than a row")

    // MARK: How much fits

    let parts = PillLayout.ordered([item(.session, 10, "session"), item(.context, 20, "context"), item(.mic, 26, "mic")], by: [])
    let l = layout(parts)
    check(l.items(1).map(\.width) == [10], "pill items: a number alone")
    let whole = l.items(parts.count)
    check(whole.map(\.id) == ["session", "context", "mic"] && whole[0].width == 10 + 52 && whole[1].width == 20 + 50,
          "pill items: bars fold into their numbers' groups")
    let dragged = layout(parts, widths: ["session": 5, "mic": 100])
    check(dragged.items(parts.count)[0].width == 20 && dragged.items(parts.count)[2].width == 100,
          "pill items: an item dragged to a width has it, 20 at the least")
    check(l.fits(0, width: 1, rows: 1), "pill: nothing always fits")
    check(l.count(width: 44, rows: 1) == 0, "pill: the character alone, nothing beside it")
    check(l.size(0, width: 500) == CGSize(width: 44, height: 44), "pill: nothing shown is the circle")
    check(l.maxWidth == 26 + 30 + 14 + 62 + 14 + 70 + 14 + 26, "pill: the widest it gets, everything in one row")
    check(l.count(width: l.maxWidth, rows: 1) == parts.count, "pill: at its widest everything shows")
    check(l.count(width: l.maxWidth - 1, rows: 1) < parts.count, "pill: a point less and something goes")
    check(l.count(width: l.maxWidth - 1, rows: 2) == parts.count, "pill: a second row takes it")
    check(l.maxHeight(width: 500) == PillLayout.height(rows: 1) && l.maxHeight(width: 1) == PillLayout.height(rows: 3), "pill: tallest at its narrowest, a row for each")

    // Never more than it can show, at any size.
    do {
        let full = layout(fullParts)
        var previous = 0
        var grows = true, sized = true
        for w in stride(from: 44 as CGFloat, through: 1400, by: 13) {
            let n = full.count(width: w, rows: 2)
            if n < previous { grows = false }
            previous = n
            if n > 0, full.size(n, width: w).width > w + 0.001 { sized = false }
        }
        check(grows, "pill: wider never shows less")
        check(sized, "pill: what it shows never needs more than the width given")
    }

    // MARK: Arranged in rows

    do {
        let full = layout(fullParts)
        let everything = full.items(fullParts.count).map(\.id)
        var clean = true, inside = true, order = true
        for w in stride(from: 60 as CGFloat, through: 1400, by: 37) {
            for h in [44, 78, 112] as [CGFloat] where !PillLayout.isVertical(width: w, height: h) {
                let a = full.arrange(width: w, height: h)
                let rects = a.ids.compactMap { a.slots[$0] }
                if rects.count != a.ids.count { clean = false }
                for (i, r) in rects.enumerated() where rects[(i + 1)...].contains(where: { overlap(r, $0) }) { clean = false }
                if rects.contains(where: { $0.minX < PillLayout.character + PillLayout.gap || $0.maxX > w - PillLayout.pad + 0.001 }) { inside = false }
                if a.ids != Array(everything.prefix(a.ids.count)) { order = false }
            }
        }
        check(clean, "pill rows: nothing on top of anything, at any size")
        check(inside, "pill rows: all of it after the character and inside the width")
        check(order, "pill rows: what shows is the start of your order")
        let a = layout(PillLayout.ordered(numbers, by: [])).arrange(width: 400, height: 44)
        check(!a.vertical && a.dividers.count == 2, "pill rows: a hairline where numbers meet metrics, and metrics meet controls")
        check(a.shown.contains(.sessionBar) && a.shown.contains(.contextBar), "pill rows: its bars count as shown")
    }

    // MARK: Arranged in a column

    do {
        let meters = PillLayout.ordered([item(.session, 10, "session"), item(.context, 20, "context")], by: [])
        let narrow = layout(meters).arrange(width: 44, height: 300)
        check(narrow.vertical && narrow.slots["session"]?.width == PillLayout.slimMeter && narrow.slots["session"]?.minY == narrow.slots["context"]?.minY,
              "pill column: pulled narrow, the bars alone, side by side")
        let mid = layout(meters).arrange(width: 100, height: 300)
        check(mid.slots["session"]?.width == PillLayout.meterWidth && mid.slots["session"]!.maxY <= mid.slots["context"]!.minY,
              "pill column: a number under each bar: one above the other when two don't fit")
        let roomy = layout(meters).arrange(width: 120, height: 300)
        check(roomy.slots["session"]?.minY == roomy.slots["context"]?.minY, "pill column: side by side once they fit")
        check(roomy.frame.height == 300, "pill column: the meters take the height asked for")
        let tall = layout(meters).arrange(width: 120, height: 500)
        check(tall.slots["session"]!.height > roomy.slots["session"]!.height, "pill column: taller bars for a taller pill")
        let unequal = layout([item(.mic, 26, "mic")]).arrange(width: 60, height: 300)
        check(unequal.frame.height < 300, "pill column: no meters to stretch, only as tall as what shows")

        let wideMetric = [item(.metric("model"), 200, "metric:model"), item(.mic, 26, "mic")]
        check(layout(wideMetric).arrange(width: 100, height: 300).ids == ["mic"], "pill column: too wide: left out")
        check(layout(wideMetric).arrange(width: 240, height: 300).ids == ["metric:model", "mic"], "pill column: pulled wide enough, it's back")
        let focus = [item(.focus, 90, "focus")]
        check(layout(focus).arrange(width: 60, height: 300).slots["focus"]?.width == 14
              && layout(focus).arrange(width: 200, height: 300).slots["focus"]?.width == 90, "pill column: the chat's name when there's room, else its dot")
        let chat = layout([item(.chat, 200, "chat")], chat: CGSize(width: 80, height: 60)).arrange(width: 200, height: 300)
        check(chat.slots["chat"]?.width == 180 && chat.slots["chat"]?.height == 60, "pill column: the chat across its width, as tall as it needs")
        check(layout([item(.chat, 200, "chat")], chat: CGSize(width: 80, height: 60)).arrange(width: 60, height: 300).ids.isEmpty,
              "pill column: narrower than the chat: no chat")
        let short = layout(meters).arrange(width: 100, height: 101)
        check(short.ids.isEmpty && short.frame.height == 2 * PillLayout.columnPad + PillLayout.character + PillLayout.sectionGap,
              "pill column: no room under the character: nothing under it")

        let spare = layout([item(.mic, 26, "mic")]).arrange(width: 300, height: 400)
        check(spare.natural == 50 && spare.frame.width == 300, "pill column: its natural width has no spare room")
        check(layout([]).arrange(width: 40, height: 200).natural == PillLayout.character + 2 * PillLayout.columnPad, "pill column: at least the character and its padding")

        var clean = true, fits = true, widthOK = true
        let full = layout(fullParts)
        for w in stride(from: 44 as CGFloat, through: 420, by: 19) {
            for h in stride(from: w + 1, through: 900, by: 53) where PillLayout.isVertical(width: w, height: h) {
                let a = full.arrange(width: w, height: h)
                let inner = max(PillLayout.character, w - 2 * PillLayout.columnPad)
                let rects = a.ids.compactMap { a.slots[$0] }
                for (i, r) in rects.enumerated() where rects[(i + 1)...].contains(where: { overlap(r, $0) }) { clean = false }
                if rects.contains(where: { $0.maxY > h - 2 * PillLayout.columnPad + 0.001 }) { fits = false }
                if rects.contains(where: { $0.minX < -0.001 || $0.maxX > inner + 0.001 }) { widthOK = false }
            }
        }
        check(clean, "pill column: nothing on top of anything, at any size")
        check(fits, "pill column: never past the height asked for")
        check(widthOK, "pill column: never past the column's sides")
    }

    // MARK: Around the camera

    do {
        var a = PillLayout.Arrangement()
        a.slots = ["left": CGRect(x: 0, y: 0, width: 10, height: 10), "right": CGRect(x: 50, y: 0, width: 10, height: 10),
                   "astride": CGRect(x: 25, y: 0, width: 10, height: 10), "below": CGRect(x: 50, y: 40, width: 10, height: 10)]
        a.dividers = [CGRect(x: 45, y: 0, width: 1, height: 10), CGRect(x: 5, y: 0, width: 1, height: 10), CGRect(x: 45, y: 40, width: 1, height: 10)]
        a.board = CGSize(width: 60, height: 50)
        a.frame = CGSize(width: 86, height: 78)
        a.natural = 86
        let roomed = a.makingRoom(at: 30, width: 100, above: 34)
        check(roomed.slots["left"]?.minX == 0 && roomed.slots["right"]?.minX == 150 && roomed.slots["astride"]?.minX == 125 && roomed.slots["below"]?.minX == 50,
              "camera: what would sit under it moves past it, rows below it stay")
        check(roomed.dividers.map(\.minX) == [145, 5, 45], "camera: so do the hairlines")
        check(roomed.frame.width == 186 && roomed.board.width == 160 && roomed.natural == 186, "camera: the pill grows by its width")
        check(a.makingRoom(at: 30, width: 0, above: 34).slots == a.slots && a.makingRoom(at: 30, width: -5, above: 34).frame == a.frame,
              "camera: none, nothing moves")
    }

    // MARK: Words and budgets

    check(PillLayout.percent(nil) == "—" && PillLayout.percent(49.5) == "50%" && PillLayout.percent(0) == "0%" && PillLayout.percent(100.4) == "100%",
          "pill: percent, rounded")
    check(PillLayout.cost(nil) == "$—" && PillLayout.cost(1.2) == "$1.20" && PillLayout.cost(0) == "$0.00" && PillLayout.cost(1234.567) == "$1234.57",
          "pill: cost, in cents")

    let first = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleWidth: CGFloat(1440))
    let second = (frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), visibleWidth: CGFloat(2560))
    typealias Screens = [(frame: CGRect, visibleWidth: CGFloat)]
    func budget(_ width: Double, density: String = "", at p: CGPoint? = nil, on screens: Screens) -> CGFloat {
        PillLayout.budget(pillWidth: width, density: density, position: p, screens: screens)
    }
    check(budget(800, on: [first, second]) == 800, "pill budget: as pulled")
    check(budget(10_000, at: CGPoint(x: 2000, y: 100), on: [first, second]) == 2560, "pill budget: pulled all the way: the screen it's on")
    check(budget(10_000, at: CGPoint(x: 9000, y: 100), on: [first]) == 1440, "pill budget: pulled wide on a monitor that's gone: the screen left")
    check(budget(800, on: []) == 800, "pill budget: no screen at all: as pulled")
    check(budget(0, density: "icon", on: [first]) == 0 && budget(0, density: "numbers", on: [first]) == 260, "pill budget: the old density settings")
    check(budget(0, on: [first]) == 1360 && budget(0, at: CGPoint(x: 2000, y: 1), on: [first, second]) == 2480, "pill budget: room for everything, within the screen it's on")
    let tiny: Screens = [(frame: CGRect(x: 0, y: 0, width: 400, height: 400), visibleWidth: 400)]
    check(budget(0, on: tiny) == 370, "pill budget: at least 370, on the smallest screen")
    check(budget(0, on: []) == 1360, "pill budget: no screen at all: as if a usual one")

    // MARK: Slots

    let flow = flowSlots([(id: "a", width: 40), (id: "b", width: 40), (id: "c", width: 40)], width: 100, rowHeight: 20, gap: 10, rowGap: 4, indent: 5)
    check(flow.slots["a"] == CGRect(x: 5, y: 0, width: 40, height: 20) && flow.slots["b"] == CGRect(x: 55, y: 0, width: 40, height: 20)
          && flow.slots["c"] == CGRect(x: 5, y: 24, width: 40, height: 20) && flow.size == CGSize(width: 95, height: 44),
          "slots: rows within the width, each from the indent")
    let oneWide = flowSlots([(id: "a", width: 300), (id: "b", width: 10)], width: 100, rowHeight: 20, gap: 10)
    check(oneWide.slots["a"]?.minY == 0 && oneWide.slots["b"]?.minY == 20 && oneWide.size.width == 300, "slots: too wide for a row takes one by itself")
    check(flowSlots([], width: 100, rowHeight: 20, gap: 10).size == CGSize(width: 0, height: 20), "slots: nothing, one empty row")
}

func runWidgetRuleChecks() {
    // MARK: Where a press pulls

    let size = CGSize(width: 200, height: 60)
    func rim(_ x: CGFloat, _ y: CGFloat) -> [Int]? { WidgetRules.pillRim(CGPoint(x: x, y: y), in: size).map { [$0.h, $0.v] } }
    check(rim(100, 30) == nil, "rim: the middle isn't the outline")
    check(rim(14, 30) == [-1, -1] && rim(15, 30) == nil, "rim: 14 pt from the left end pulls it, with the bottom")
    check(rim(186, 30) == [1, -1] && rim(185, 30) == nil, "rim: 14 pt from the right end")
    check(rim(100, 7) == [-1, -1] && rim(100, 8) == nil, "rim: the bottom band")
    check(rim(100, 53) == [-1, 1] && rim(101, 53) == [1, 1] && rim(100, 52) == nil, "rim: the top band pulls the top, and the nearer end")
    check(rim(0, 0) == [-1, -1] && rim(200, 60) == [1, 1], "rim: the corners")

    // MARK: What a pull comes to

    let from = CGSize(width: 300, height: 44)
    check(WidgetRules.rawPull(from: from, h: 1, v: -1, dx: 20, dy: -10, centered: false) == CGSize(width: 320, height: 54), "pull: right end out, bottom down")
    check(WidgetRules.rawPull(from: from, h: -1, v: 1, dx: 20, dy: 10, centered: false) == CGSize(width: 280, height: 54), "pull: left end pushed in, top up")
    check(WidgetRules.rawPull(from: from, h: 1, v: -1, dx: 20, dy: 0, centered: true).width == 340, "pull: at the default spot it grows both ways")

    let compactAt: CGFloat = 300
    func notch(_ raw: CGSize, most: CGFloat = 900, room: CGSize = CGSize(width: 1400, height: 800)) -> (width: Double, height: Double) {
        WidgetRules.notchRelease(raw: raw, compactWidth: compactAt, most: most, room: room, rowHeight: 44)
    }
    check(notch(CGSize(width: 324, height: 300)).width == 0 && notch(CGSize(width: 324, height: 300)).height == 0, "island let go: within 24 pt of compact, compact again")
    check(notch(CGSize(width: 325, height: 300)).width == 325 && notch(CGSize(width: 325, height: 300)).height == 300, "island let go: past that, as pulled")
    check(notch(CGSize(width: 2000, height: 30)).width == 900 && notch(CGSize(width: 2000, height: 30)).height == 44, "island let go: no wider than all it shows, at least a row")
    check(notch(CGSize(width: 2000, height: 3000), room: CGSize(width: 500, height: 700)).width == 500
          && notch(CGSize(width: 2000, height: 3000), room: CGSize(width: 500, height: 700)).height == 700, "island let go: within the screen")

    let room = CGSize(width: 600, height: 500)
    check(WidgetRules.pillRelease(raw: CGSize(width: 400, height: 80), room: room, minWidth: 44, rowHeight: 44) == CGSize(width: 400, height: 80), "pill let go: as pulled")
    check(WidgetRules.pillRelease(raw: CGSize(width: 2000, height: 2000), room: room, minWidth: 44, rowHeight: 44) == room, "pill let go: where it showed, not where the pointer went")
    check(WidgetRules.pillRelease(raw: CGSize(width: -50, height: -50), room: room, minWidth: 44, rowHeight: 44) == CGSize(width: 44, height: 44), "pill let go: pulled past nothing: the circle")
    check(WidgetRules.pillRelease(raw: CGSize(width: 100, height: 10), room: CGSize(width: 30, height: 20), minWidth: 44, rowHeight: 44) == CGSize(width: 44, height: 20),
          "pill let go: its least width even with no room for it")
    check(WidgetRules.savedWidth(raw: 800, shown: 600, most: 700, room: 900) == 10_000, "pill let go: pulled all the way: everything, now and later")
    check(WidgetRules.savedWidth(raw: 800, shown: 600, most: 700, room: 650) == 600, "pill let go: all the way but no room for it: what showed")
    check(WidgetRules.savedWidth(raw: 650, shown: 650, most: 700, room: 900) == 650, "pill let go: short of all of it: as pulled")

    // MARK: Who has the keyboard

    func wants(_ mode: WidgetMode, request: Bool = false, queue: Bool = false, typing: Bool = false, dictated: Bool = false) -> Bool {
        WidgetRules.wantsKey(mode: mode, request: request, taskQueue: queue, pillTyping: typing, dictated: dictated)
    }
    check(!wants(.strip) && !wants(.pill) && !wants(.panel), "keyboard: at rest it stays with your editor")
    check(wants(.panel, request: true) && wants(.panel, queue: true), "keyboard: the panel for a request's field and the queue's")
    check(wants(.chats) && wants(.chats, request: true), "keyboard: the Chats tab, for its composers")
    check(wants(.pill, typing: true) && wants(.pill, dictated: true), "keyboard: the pill while writing there, or a dictation being checked")
    check(!wants(.strip, request: true, queue: true, typing: true, dictated: true), "keyboard: never the thin line")
    check(!wants(.pill, request: true, queue: true), "keyboard: a request alone doesn't take it from the pill")
    check(!wants(.panel, typing: true, dictated: true), "keyboard: writing in the pill says nothing of the panel")

    // MARK: Sizes and rows

    check(WidgetRules.light(0xFFD60A) && WidgetRules.light(0x63E6BE) && !WidgetRules.light(0x0A84FF) && !WidgetRules.light(0xBF5AF2) && !WidgetRules.light(0),
          "chat colours: a dark icon on yellow and mint only")
    check(WidgetRules.rows([50, 50, 50], within: 100, gap: 10) == [[0], [1], [2]] && WidgetRules.rows([40, 50, 50], within: 100, gap: 10) == [[0, 1], [2]],
          "panel rows: greedy, the gap counted")
    check(WidgetRules.rows([300], within: 100, gap: 10) == [[0]] && WidgetRules.rows([], within: 100, gap: 10) == [[]], "panel rows: too wide takes a row; nothing, one empty row")

    check(NotchSizes.compactWidth(camera: 200) == 16 + 22 + 184 + 200 && NotchSizes.compactWidth(camera: 0) == 16 + 22 + 210, "island: compact around a camera, or drawn")
    check(NotchSizes.grownWidth(camera: 0) == 460 && NotchSizes.grownWidth(camera: 400) == 664, "island: grown, at least 460")
    func camera(_ top: CGFloat, _ l: CGFloat?, _ r: CGFloat?) -> [CGFloat] { let n = NotchSizes.notch(safeTop: top, leftMaxX: l, rightMinX: r); return [n.width, n.height] }
    check(camera(0, nil, nil) == [0, 32] && camera(0, 100, 300) == [0, 32], "notch: no safe area: none, one is drawn")
    check(camera(37, 650, 850) == [200, 37], "notch: the camera between the menu bar's two areas")
    check(camera(37, nil, 850) == [200, 37] && camera(37, 650, nil) == [200, 37], "notch: an area not told: a usual width")
    check(camera(37, 900, 850) == [0, 37], "notch: areas that overlap: no width, never less")

    // MARK: Pulling on two screens

    let macBook = WidgetPlace.Display(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 0, width: 1512, height: 945), notch: true)
    let monitor = WidgetPlace.Display(frame: CGRect(x: 0, y: 982, width: 2560, height: 1440), visible: CGRect(x: 0, y: 982, width: 2560, height: 1400), notch: false)
    let hanging = WidgetPlace.frame(size: CGSize(width: 300, height: 44), anchor: CGPoint(x: 756, y: 945), fixed: nil, docked: false, displays: [macBook, monitor])
    let pullRoom = WidgetPlace.room(frame: hanging, bounds: macBook.visible, h: 1, v: -1, centered: true)
    let pulled = WidgetPlace.pulled(raw: WidgetRules.rawPull(from: hanging.size, h: 1, v: -1, dx: 5000, dy: -5000, centered: true),
                                    low: CGSize(width: 44, height: 44), most: CGSize(width: 9000, height: 9000), room: pullRoom)
    check(hanging.maxY == 945 && hanging.midX == 756, "pull: under the MacBook's menu bar, not on the monitor above")
    check(pulled.width <= macBook.visible.width && pulled.height <= macBook.visible.height, "pull: never past the screen it's on")
}
