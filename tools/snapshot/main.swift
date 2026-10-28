import AppKit
import SwiftUI

// Renders the Touch Bar in every mode to PNGs (2x, as on the real bar), so
// the layout can be checked against design/TB-*.dc.html without a Touch Bar
// in front. Not part of the app: `make snapshots`.
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/snapshots")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let three = Config().effectiveButtons
let seven = three + ["review", "run tests", "/clear", "commit"].map {
    ButtonSpec(label: $0, type: .command, value: $0)
}

var cases: [(String, BarModel, CGFloat)] = []
func add(_ name: String, width: CGFloat = BarView.preferredWidth, _ edit: (inout BarModel) -> Void) {
    var m = BarModel(mode: .normal, activity: .work, sessionPercent: 42, resetCountdown: "1:23",
                     contextPercent: 31, buttons: three)
    edit(&m)
    cases.append((name, m, width))
}
add("normal-3") { _ in }
add("normal-0") { $0.buttons = [] }
do { // the short bar keeps every block Settings lets in, in every combination (owner, 26.10: "say when there's no room")
    let options = ["name", "session", "context", "chat", "shot", "mic", "reset", "model", "agents", "lines", "branch", "cost", "templates"]
    var checked = 0
    for mask in 0..<(1 << options.count) {
        let shows = Set(options.indices.filter { mask & (1 << $0) != 0 }.map { options[$0] })
        guard BarView.shortFits(shows) else { continue }
        var m = BarModel(mode: .normal, activity: .work, sessionPercent: 42, resetCountdown: "1:23", contextPercent: 31, buttons: three)
        m.short = true; m.shows = shows; m.project = "DiaRoute"; m.lines = "+1 −1"
        let bar = BarView(frame: NSRect(x: 0, y: 0, width: BarView.narrowWidth, height: Palette.height))
        bar.update(m)
        bar.layoutSubtreeIfNeeded()
        let keys = Set(bar.blocks.map(\.key))
        let expected = Set(shows.map { $0 == "session" || $0 == "context" ? "meters" : $0 })
        if !expected.isSubset(of: keys) {
            print("FAIL short bar: \(shows.sorted()) fits by Settings, but \(expected.subtracting(keys).sorted()) left out")
            exit(1)
        }
        checked += 1
    }
    print("short bar: \(checked) sets that fit, every block shown")
    // A bar a little narrower than measured (another Mac, another Control Strip): the chat line gives way first.
    var m = BarModel(mode: .normal, activity: .work, sessionPercent: 42, resetCountdown: "1:23", contextPercent: 31, buttons: three)
    m.short = true; m.shows = ["name", "session", "context", "chat", "shot", "mic"]; m.project = "DiaRoute"
    let narrow = BarView(frame: NSRect(x: 0, y: 0, width: BarView.narrowWidth - 40, height: Palette.height))
    narrow.update(m)
    narrow.layoutSubtreeIfNeeded()
    let keys = Set(narrow.blocks.map(\.key))
    if !Set(["name", "meters", "chat", "shot", "mic"]).isSubset(of: keys) {
        print("FAIL short bar 40 pt narrower: left out \(Set(["name", "meters", "chat", "shot", "mic"]).subtracting(keys).sorted())")
        exit(1)
    }
}
for (name, shows) in [("short-default", ["name", "session", "context", "chat", "shot", "mic"]),
                      ("short-chat", ["name", "session", "context", "chat"]),
                      ("short-many", ["name", "session", "context", "model", "lines", "cost", "templates", "shot", "mic"]),
                      ("short-tools", ["name", "session", "context", "reset", "model", "templates", "shot"])] {
    add(name, width: BarView.narrowWidth) { // the short bar's own set, fixed sizes; what doesn't fit is left for the whole bar
        $0.short = true; $0.shows = Set(shows); $0.project = "DiaRoute"; $0.modelLabel = "Opus 5.5 1M · xhigh"; $0.lines = "+120 −8"
        $0.chats = [BarModel.Chat(id: "1", name: "Offline routes", color: Session.colors[0], current: true, waiting: false)]
    }
}
add("question-long") { // the same question on the Touch Bar
    $0.mode = .question(text: "Как поступим с музыкой? Трендовые песни из TikTok — чужие, в рекламе для всех площадок их брать нельзя без лицензии.",
                        options: ["Новый трек в стиле трендов (Recommended)", "Лицензионный трек — пришлю файл", "Версия без музыки для TikTok"],
                        multiSelect: false, picked: [])
    $0.activity = .wait
}
add("whole-reset") { // the reset as a block of its own on the whole bar, seen however narrow the meters are
    $0.shows = ["session", "reset", "context", "chat", "buttons", "templates", "cost", "shot", "mic"]; $0.cost = "$1.20"
    $0.templates = ["Continue"]; $0.chatName = "Status bar"
}
add("whole-reset-arranged") { // arranged in 1.1.2, before the reset was a block: it comes right after the meters, not last
    $0.shows = ["session", "reset", "context", "chat", "buttons", "templates", "cost", "shot", "mic"]; $0.cost = "$1.20"
    $0.templates = ["Continue"]; $0.chatName = "Status bar"; $0.order = ["meters", "chat", "cost", "templates", "shot", "mic"]
}
add("normal-unknown") { // a chat whose model, lines, branch and cost aren't known yet (VS Code has no cost): "—", the menu empty
    $0.shows = ["session", "context", "model", "lines", "branch", "cost", "templates", "shot", "mic"]
    $0.chatName = "Status bar"; $0.chats = [BarModel.Chat(id: "1", name: "Status bar", color: Session.colors[0], current: true, waiting: false)]
}
add("normal-5") { $0.buttons = Array(seven.prefix(5)) }
add("normal-7") { $0.buttons = seven }
add("normal-pick-context-mic") { $0.shows = ["context", "buttons", "mic", "shot"] }
add("normal-pick-session") { $0.shows = ["session"] }
add("normal-sleep-nodata") { $0.activity = .sleep; $0.sessionPercent = nil; $0.contextPercent = nil; $0.resetCountdown = nil }
add("normal-orange-red") { $0.sessionPercent = 74; $0.contextPercent = 93 }
add("permission") { $0.activity = .wait; $0.mode = .permission(verb: "Run", detail: "npm run build && npm test") }
add("permission-long") { $0.activity = .wait; $0.mode = .permission(verb: "Run", detail: String(repeating: "find . -name '*.swift' | xargs grep -n TODO ", count: 4)) }
add("question") { $0.activity = .wait; $0.mode = .question(text: "Storage for offline routes?", options: ["SQLite", "MMKV", "AsyncStorage"], multiSelect: false, picked: []) }
add("question-multi") { $0.activity = .wait; $0.mode = .question(text: "Which platforms?", options: ["iOS", "Android", "Web", "macOS"], multiSelect: true, picked: [0, 2]) }
add("typing-short") { $0.activity = .wait; $0.mode = .typing(text: "WatermelonDB for now") }
add("typing-long") { $0.activity = .wait; $0.mode = .typing(text: "WatermelonDB for now, add sync to the backend in the next sprint") }
add("typing-verylong") { $0.activity = .wait; $0.mode = .typing(text: "WatermelonDB for now, add sync to the backend in the next sprint, and keep the offline cache small enough for old phones") }
add("typing-empty") { $0.activity = .wait; $0.mode = .typing(text: "") }
add("context-warning") { $0.activity = .sleep; $0.sessionPercent = 74; $0.resetCountdown = "0:41"; $0.contextPercent = 91; $0.mode = .contextWarning }
add("normal-narrow-controlstrip", width: 685) { _ in }
add("normal-model") { $0.shows = ["session", "reset", "context", "model", "buttons"]; $0.modelLabel = "Opus 5.5 1M · xhigh" }
add("models") { $0.mode = .models; $0.modelAlias = "opus[1m]"; $0.effort = "xhigh" }
add("models-narrow", width: 685) { $0.mode = .models; $0.modelAlias = "sonnet"; $0.effort = "high" }
add("agents") { $0.mode = .agents; $0.agents = ["Explore · Find the hook code", "general-purpose · Check transcripts", "Plan · Design the picker"] }
add("normal-agents") { $0.shows = ["session", "context", "model", "agents", "buttons"]; $0.modelLabel = "Opus 5.5 1M · xhigh"; $0.agents = ["a", "b"] }
let chats = [BarModel.Chat(id: "1", name: "Status bar", color: Session.colors[0], current: true, waiting: false),
             BarModel.Chat(id: "2", name: "Lead bot", color: Session.colors[1], current: false, waiting: true),
             BarModel.Chat(id: "3", name: "Portfolio site redesi…", color: Session.colors[2], current: false, waiting: false)]
add("normal-chats") { $0.chats = chats }
add("chats") { $0.chats = chats; $0.mode = .chats }
let longChats = [BarModel.Chat(id: "1", name: "привет, давай разберём тесты в модуле оплаты", color: Session.colors[3], current: true, waiting: false),
                 BarModel.Chat(id: "2", name: "Промо-ролик для лендинга", color: Session.colors[1], current: false, waiting: false)]
add("normal-longchat") { $0.chats = longChats }
// Short names (owner, 27.10): they fit, nothing slides; a long one is cut with "…".
let shortChats = [BarModel.Chat(id: "1", name: "Правка карусели", color: Session.colors[3], current: true, waiting: false),
                  BarModel.Chat(id: "2", name: "Login test", color: Session.colors[1], current: false, waiting: false)]
add("normal-shortchat") { $0.chats = shortChats }
// Dragged to the narrowest: the dot and the letter are one, a bold capital in the chat's colour.
for (i, name) in [(0, "blue"), (6, "indigo"), (3, "green"), (5, "yellow")] {
    let one = [BarModel.Chat(id: "1", name: "Правка карусели", color: Session.colors[i], current: true, waiting: false), shortChats[1]]
    add("normal-letter-" + name) { $0.chats = one; $0.widths["name"] = 44 }
}
add("chats-long") { $0.chats = longChats + chats; $0.mode = .chats }
// Many chats, Cowork ones among them (long Russian names): each keeps a readable name.
let manyChats = chats + [BarModel.Chat(id: "4", name: "Ролик для презентации", color: Session.colors[4], current: false, waiting: false),
                         BarModel.Chat(id: "5", name: "Блог: черновики постов", color: Session.colors[5], current: false, waiting: false),
                         BarModel.Chat(id: "6", name: "Рассылка: шаблоны писем", color: Session.colors[6], current: false, waiting: false)]
add("chats-many") { $0.chats = manyChats; $0.mode = .chats }
add("chats-many-short", width: 628) { $0.short = true; $0.chats = manyChats; $0.mode = .chats }
let crowd = manyChats + [BarModel.Chat(id: "7", name: "Анимация логотипа", color: Session.colors[7], current: false, waiting: false),
                        BarModel.Chat(id: "8", name: "claudebar", color: Session.colors[0], current: false, waiting: false),
                        BarModel.Chat(id: "9", name: "Docs: сайт", color: Session.colors[1], current: false, waiting: false)]
add("chats-crowd") { $0.chats = crowd; $0.mode = .chats }
add("chats-crowd-short", width: 628) { $0.short = true; $0.chats = crowd; $0.mode = .chats }
add("done") { $0.chats = chats; $0.mode = .done(BarModel.Chat(id: "4", name: "Cowork · Ролик для презентации", color: Session.colors[4], current: false, waiting: false)) }
add("done-short", width: 628) { $0.short = true; $0.chats = chats; $0.mode = .done(chats[1]) }
add("permission-chat") { $0.chats = chats; $0.requestChat = chats[1]; $0.activity = .wait
    $0.mode = .permission(verb: "Run", detail: "npm run deploy") }
add("normal-write-templates") { $0.shows = ["session", "reset", "context", "lines", "branch", "chat", "templates", "buttons", "mic"]
    $0.lines = "+120 −8"; $0.branch = "clouding-bar"; $0.templates = ["Review {branch}", "Write tests"]; $0.chats = chats
    $0.chatName = "Status bar" }
add("templates") { $0.mode = .templates; $0.templates = ["Review the changes on {branch}", "Write tests for this", "Explain this error: {clipboa…"] }
add("compose") { $0.mode = .typing(text: "Check the landing page on mobile too"); $0.typingLabel = "To Status bar"
    $0.typingPlaceholder = "Sent when Claude is free"; $0.typingCommands = true
    $0.shows = ["session", "context", "templates", "buttons"]; $0.templates = ["Review {branch}"] }
add("compose-empty") { $0.mode = .typing(text: ""); $0.typingLabel = "To Status bar"; $0.typingPlaceholder = "Sent when Claude is free" }
// The line written for a chat picked from the list, not the one followed (owner, 27.10): its chip, a screenshot waiting, ↗.
add("compose-to") { $0.chats = chats; $0.mode = .typing(text: "Look at the screenshot: the form overlaps the footer")
    $0.typingTo = chats[1]; $0.typingFiles = 1; $0.typingPlaceholder = "Type on the keyboard…" }
add("compose-to-empty") { $0.chats = chats; $0.mode = .typing(text: ""); $0.typingTo = chats[2]; $0.typingPlaceholder = "Type on the keyboard…" }
add("compose-to-long") { $0.chats = longChats; $0.mode = .typing(text: "Проверь тесты в модуле оплаты и почини, что упало")
    $0.typingTo = longChats[0]; $0.typingPlaceholder = "Type on the keyboard…"; $0.listening = true }
add("normal-short", width: 628) { $0.short = true; $0.chats = chats
    $0.shows = ["session", "reset", "context", "model", "buttons", "mic"]; $0.modelLabel = "Opus 5.5 1M" }
add("normal-short-all", width: 628) { $0.short = true; $0.chats = chats; $0.buttons = seven
    $0.shows = ["session", "reset", "context", "model", "lines", "chat", "templates", "buttons", "shot", "mic"]
    $0.modelLabel = "Opus 5.5 1M"; $0.lines = "+120 −8"; $0.templates = ["Review"] }
let mine = ["caveman", "compact", "office"].map { ButtonSpec(label: $0, type: .command, value: $0) }
add("normal-arranged") { $0.chats = chats; $0.buttons = mine; $0.shows = ["session", "reset", "context", "chat", "buttons", "shot", "mic"]
    $0.order = ["chat", "meters", "mic", "name"]; $0.widths = ["meters": 200, "name": 90] }
add("normal-short-arranged", width: 628) { $0.short = true; $0.chats = chats; $0.buttons = mine
    $0.shows = ["session", "reset", "context", "chat", "buttons"]; $0.order = ["chat", "meters"]; $0.widths = ["meters": 220, "chat": 260] }
add("normal-short-3", width: 628) { $0.short = true; $0.chats = chats; $0.buttons = mine + Array(seven.suffix(2))
    $0.shows = ["reset", "session", "context", "mic", "shot", "chat", "buttons"] }
add("normal-short-1", width: 628) { $0.short = true; $0.chats = chats; $0.buttons = Array(mine.suffix(1))
    $0.shows = ["reset", "session", "context", "mic", "shot", "chat", "buttons"] }
// The README's pictures of the bar: the whole one, and the short one beside Apple's buttons.
add("readme-touchbar") { $0.chats = chats; $0.buttons = three; $0.modelLabel = "Opus 5.5 1M · xhigh"
    $0.shows = ["session", "reset", "context", "model", "chat", "buttons", "mic"] }
add("readme-touchbar-short", width: 628) { $0.short = true; $0.chats = chats; $0.buttons = three; $0.project = "Status bar"
    $0.shows = ["name", "session", "context", "chat", "shot", "mic"] }
add("normal-expanded") { $0.expanded = true; $0.chats = chats; $0.buttons = seven
    $0.shows = ["session", "reset", "context", "model", "chat", "buttons", "mic"]; $0.modelLabel = "Opus 5.5 1M" }
add("permission-short", width: 628) { $0.short = true; $0.chats = chats; $0.requestChat = chats[1]; $0.activity = .wait
    $0.mode = .permission(verb: "Run", detail: "npm run deploy -- --prod") }
add("question-short", width: 628) { $0.short = true; $0.activity = .wait
    $0.mode = .question(text: "Storage for offline routes?", options: ["SQLite", "MMKV", "AsyncStorage"], multiSelect: false, picked: []) }
add("compose-short-long", width: 628) { $0.short = true; $0.buttons = three
    $0.mode = .typing(text: "Check the landing page on mobile too, and the form at the bottom of it")
    $0.typingLabel = "To Status bar"; $0.typingPlaceholder = "Sent when Claude is free"; $0.typingCommands = true; $0.shows = ["buttons"] }
add("compose-short", width: 628) { $0.short = true; $0.mode = .typing(text: "Check the landing page on mobile too")
    $0.typingLabel = "To Status bar"; $0.typingPlaceholder = "Sent when Claude is free"; $0.typingCommands = true; $0.shows = ["buttons"] }
add("normal-model-narrow", width: 685) { $0.shows = ["session", "context", "model", "buttons"]; $0.modelLabel = "Opus 5.5 1M · xhigh" }

var images: [CGImage] = []
for (name, model, width) in cases {
    let view = BarView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = view
    view.update(model)
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    // Let layer-backed text draw once.
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    view.layer?.removeAllAnimationsRecursively()

    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(30 * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.cgContext.scaleBy(x: scale, y: scale)
    view.layer?.render(in: ctx.cgContext)
    let url = out.appendingPathComponent("\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    if let cg = rep.cgImage { images.append(cg) }
}

// MARK: Widget and settings (SwiftUI), on the mockups' #1B1B1D desktop

func renderView(_ view: NSView, size: NSSize, name: String, light: Bool = false) {
    let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = NSColor(hex: 0x1B1B1D).cgColor
    view.frame = NSRect(origin: .zero, size: size)
    backdrop.addSubview(view)
    let window = NSWindow(contentRect: backdrop.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    window.contentView = backdrop
    backdrop.layoutSubtreeIfNeeded()
    backdrop.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(name.hasPrefix("s-stats") ? 4 : 1.2)) // animations, stats
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.cgContext.scaleBy(x: scale, y: scale)
    backdrop.layer?.render(in: ctx.cgContext)
    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
}

func sampleModel() -> AppModel {
    let m = AppModel()
    m.barPreview = { short in // the bar Settings arranges
        var b = BarModel()
        b.short = short; b.chats = chats; b.buttons = three
        b.shows = ["session", "reset", "context", "chat", "buttons", "shot", "mic"]
        b.sessionPercent = 42; b.contextPercent = 31; b.resetCountdown = "1:23"; b.chatName = "Status bar"
        return b
    }
    m.config.sessionsList = true
    m.hasSession = true
    m.activity = .work
    m.project = "DiaRoute"
    m.sessionPercent = 42
    m.resetShort = "1:23"
    m.resetLong = "1 h 23 min"
    m.contextPercent = 31
    m.contextTokens = 312_400
    m.contextWindow = 1_000_000
    m.tokensIn = 41_200
    m.tokensOut = 2_300
    m.chatName = "Offline routes"
    m.chatColor = Session.colors[0]
    m.chatPlace = "DiaRoute · VS Code"
    m.chatStatus = "Working · 3 min"
    m.buttons = Config().effectiveButtons
    m.sessions = [
        .init(id: "1", name: "Offline routes", status: "Working · 3 min", activity: .work, context: 31, waiting: false,
              place: "DiaRoute · VS Code", color: Session.colors[0], current: true),
        .init(id: "2", name: "Lead bot", status: "Needs your OK", activity: .wait, context: 58, waiting: true,
              place: "bots · Cowork", color: Session.colors[1]),
        .init(id: "3", name: "Status bar", status: "Working · 9 min", activity: .work, context: 83, waiting: false,
              place: "GitHub · VS Code", color: Session.colors[2]),
        .init(id: "4", name: "claudebar", status: "Idle · 12 min", activity: .sleep, context: 94, waiting: false,
              place: "Terminal", color: Session.colors[3]),
        .init(id: "5", name: "Portfolio site redesign", status: "Idle · 1 h", activity: .sleep, context: 12, waiting: false,
              place: "GitHub · VS Code", color: Session.colors[4]),
    ]
    return m
}

func widget(_ name: String, _ mode: WidgetMode, size: NSSize = NSSize(width: 400, height: 480),
            _ edit: (AppModel) -> Void = { _ in }) {
    let m = sampleModel()
    edit(m)
    let state = WidgetState()
    state.mode = mode
    let host = NSHostingView(rootView: VStack { WidgetView(model: m, state: state); Spacer() }
        .frame(width: size.width, height: size.height).padding(.top, 20))
    renderView(host, size: size, name: name)
}

do { // Cloud, the classic one (no chat's variant)
    let v = MascotView(size: 44)
    v.activity = .sleep
    v.awake = true
    renderView(v, size: NSSize(width: 60, height: 60), name: "w-cloud-classic")
}
do { // Cloud tells another chat is done
    let anim = DoneBubbleAnimation()
    anim.alert = DoneBubbleController.Alert(id: "c", name: "Ролик для презентации", detail: "Notes · Cowork", color: Session.colors[4])
    anim.out = 1
    anim.bubble = 1
    renderView(NSHostingView(rootView: DoneBubbleView(anim: anim, open: {}, hover: { _ in })),
               size: DoneBubbleController.size, name: "w-done-bubble")
}

widget("w-strip", .strip, size: NSSize(width: 200, height: 60))
widget("w-pill", .pill, size: NSSize(width: 400, height: 90))
widget("w-pill-cloud-out", .pill, size: NSSize(width: 1000, height: 90)) { $0.cloudOut = 1 } // out saying another chat is done
widget("w-pill-cloud-home", .pill, size: NSSize(width: 1000, height: 90))
widget("w-pill-cost", .pill, size: NSSize(width: 400, height: 90)) { $0.config.pillShows = ["context", "reset", "cost"]; $0.cost = 0.84 }
widget("w-pill-minimal", .pill, size: NSSize(width: 400, height: 90)) { $0.hasSession = false; $0.activity = .sleep }
widget("w-pill-request", .pill, size: NSSize(width: 400, height: 90)) {
    $0.request = .init(id: UUID(), kind: .permission, project: "DiaRoute", verb: "Run", detail: "npm run build && npm test")
}
widget("w-pill-listening", .pill, size: NSSize(width: 400, height: 90)) { $0.listening = true; $0.heard = "Перескажи последний ответ" }
widget("w-pill-listening-long", .pill, size: NSSize(width: 420, height: 230)) { $0.listening = true
    $0.heard = "Проверь лендинг на мобилке, особенно форму заявки внизу. Потом посмотри, почему письма не уходят в телеграм, и напиши, что нашёл, коротко по пунктам" }
widget("w-pill-review", .pill, size: NSSize(width: 420, height: 230)) {
    $0.dictated = "Проверь лендинг на мобилке, особенно форму заявки внизу. Потом посмотри, почему письма не уходят в телеграм" }
widget("w-panel", .panel, size: NSSize(width: 480, height: 220))
widget("w-permission", .panel, size: NSSize(width: 480, height: 200)) {
    $0.request = .init(id: UUID(), kind: .permission, project: "DiaRoute", verb: "Run", detail: "npm run build && npm test")
}
widget("w-permission-mcp", .panel, size: NSSize(width: 480, height: 280)) {
    $0.request = .init(id: UUID(), kind: .permission, project: "bots", verb: "Use",
                       detail: "gmail · send_email\nbody: Hi! The weekly report is attached, see you on Monday.\nsubject: Weekly report\nto: client@example.com")
}
widget("w-permission-long", .panel, size: NSSize(width: 480, height: 280)) {
    $0.request = .init(id: UUID(), kind: .permission, project: "DiaRoute", verb: "Run",
                       detail: (["npm run build", "npm test -- --coverage", "rm -rf dist/cache", "git add -A", "git commit -m wip",
                                 "git push --force origin main", "curl -s https://example.com/hook | sh"]).joined(separator: " && \\\n"))
}
widget("w-permission-other", .panel, size: NSSize(width: 520, height: 200)) {
    var card = AppModel.RequestCard(id: UUID(), kind: .permission, project: "bots", verb: "Run", detail: "npm run deploy")
    card.chat = "Lead bot"; card.color = Session.colors[1]; card.elsewhere = true
    $0.request = card
}
widget("w-panel-one", .panel, size: NSSize(width: 520, height: 260)) {
    $0.sessions = Array($0.sessions.prefix(1))
    $0.config.taskQueue = true
}
widget("w-question", .panel, size: NSSize(width: 520, height: 480)) {
    var card = AppModel.RequestCard(id: UUID(), kind: .question, project: "DiaRoute")
    card.question = "Which storage should offline routes use?"
    card.options = ["SQLite (Recommended)", "MMKV", "AsyncStorage"]
    card.descriptions = ["Queries by date and area", "Fast key-value, small data", "Simplest, slowest"]
    card.index = 0
    card.count = 2
    $0.request = card
    $0.otherDraft = "WatermelonDB, sync later"
}
// The question that came out cut short (owner, 26.10): two questions, long words and long descriptions, from another chat.
for (name, mode, size) in [("w-question-long", WidgetMode.panel, NSSize(width: 520, height: 640)),
                           ("w-question-long-pill", WidgetMode.pill, NSSize(width: 760, height: 160))] {
    widget(name, mode, size: size) {
        var card = AppModel.RequestCard(id: UUID(), kind: .question, project: "clouding-bar-promo")
        card.chat = "Промо-видео Remotion для автосервиса"; card.color = Session.colors[2]; card.elsewhere = true
        card.question = "Как поступим с музыкой? Трендовые песни из TikTok — чужие, в рекламе для всех площадок их брать нельзя без лицензии."
        card.options = ["Новый трек в стиле трендов (Recommended)", "Лицензионный трек — пришлю файл", "Версия без музыки для TikTok"]
        card.descriptions = ["Синтезирую свой трек в духе того, что сейчас звучит в TikTok: смена ритма по главам, стопы, дропы, «вокальные» хуки. Без проблем с правами, синхронизирую с каждым событием.",
                             "Вы берёте трек на Artlist, Epidemic или Uppbeat (с лицензией на все площадки) и кладёте мне файл. Я подгоню монтаж под его биты и дропы.",
                             "Делаю ролик только со звуками интерфейса, а трендовый звук вы добавляете в самом TikTok при публикации (из библиотеки для бизнеса). Для других площадок — мой трек."]
        card.index = 0
        card.count = 2
        $0.request = card
    }
}
widget("w-panel-extras", .panel, size: NSSize(width: 720, height: 330)) {
    $0.config.metrics = ["model", "lines", "git", "agents"]
    $0.menuButtons = [ButtonSpec(label: "Continue", type: .text, value: "Continue", menu: true)]
    $0.config.screenshot = true
    $0.config.taskQueue = true
    $0.modelName = "Opus 5.5 1M"; $0.effort = "xhigh"
    $0.linesAdded = 214; $0.linesRemoved = 37; $0.branch = "clouding-bar"; $0.agents = 2
    $0.queue = [.init(text: "Run the tests and fix what fails", sessionId: nil, project: nil),
                .init(text: "Update the README", sessionId: nil, project: nil)]
}
widget("w-panel-arranged", .panel, size: NSSize(width: 720, height: 360)) { // blocks, tools and time moved by hand
    $0.config.metrics = ["model", "time", "lines", "git"]
    $0.config.screenshot = true
    $0.config.taskQueue = true
    $0.config.panelOrder = ["box", "details", "meters"]
    $0.config.itemOrder = ["mic", "send"]
    $0.modelName = "Opus 5.5 1M"; $0.effort = "xhigh"; $0.chatTime = "3 min"; $0.chatStatus = "Working"
    $0.linesAdded = 214; $0.linesRemoved = 37; $0.branch = "clouding-bar"
}
widget("w-panel-all", .panel, size: NSSize(width: 720, height: 360)) {
    $0.config.metrics = ["model", "lines", "git", "agents"]
    $0.menuButtons = [ButtonSpec(label: "Continue", type: .text, value: "Continue", menu: true)]
    $0.config.screenshot = true
    $0.config.taskQueue = true
    $0.config.sessionsList = true
    $0.modelName = "Opus 5.5 1M"; $0.effort = "xhigh"
    $0.linesAdded = 214; $0.linesRemoved = 37; $0.branch = "clouding-bar"; $0.agents = 2
    $0.buttons = $0.buttons + [ButtonSpec(label: "review", type: .command, value: "/review"),
                               ButtonSpec(label: "run tests", type: .phrase, value: "run tests")]
}
widget("w-pill-numbers", .pill, size: NSSize(width: 400, height: 90)) { $0.config.pillDensity = "numbers" }
widget("w-pill-icon", .pill, size: NSSize(width: 400, height: 90)) { $0.config.pillDensity = "icon" }
widget("w-pill-sized", .pill, size: NSSize(width: 1000, height: 90)) { // items dragged wider by their edge
    $0.config.pillWidth = 10_000
    $0.config.taskQueue = true
    $0.config.screenshot = true
    $0.config.itemWidths = ["session": 170, "chat": 330, "mic": 44]
}
widget("w-pill-wide", .pill, size: NSSize(width: 1300, height: 90)) {
    $0.config.pillWidth = 10_000
    $0.config.metrics = ["model", "lines", "git", "agents"]
    $0.config.screenshot = true
    $0.modelName = "Opus 5.5 1M"; $0.effort = "xhigh"
    $0.linesAdded = 214; $0.linesRemoved = 37; $0.branch = "clouding-bar"; $0.agents = 2
}
widget("w-pill-rows", .pill, size: NSSize(width: 600, height: 170)) {
    $0.config.pillWidth = 470; $0.config.pillRows = 3
    $0.config.metrics = ["model", "lines", "git", "agents"]
    $0.config.screenshot = true
    $0.modelName = "Opus 5.5 1M"; $0.effort = "xhigh"
    $0.linesAdded = 214; $0.linesRemoved = 37; $0.branch = "clouding-bar"; $0.agents = 2
}
widget("w-pill-chat", .pill, size: NSSize(width: 900, height: 90)) {
    $0.config.pillWidth = 10_000; $0.config.taskQueue = true
    $0.config.metrics = ["model", "agents"]; $0.modelName = "Opus 5.5 1M"; $0.agents = 2
    $0.config.itemOrder = ["session", "context", "reset", "cost", "metric:agents", "metric:model"]
}
for (name, width, height) in [("w-pill-column", 64.0, 520.0), ("w-pill-column-wide", 190.0, 520.0),
                              ("w-pill-column-slim", 44.0, 520.0)] {
    let m = sampleModel()
    m.config.pillWidth = width; m.config.pillHeight = height; m.config.taskQueue = true; m.config.screenshot = true
    m.config.metrics = ["model", "lines", "git", "agents"]; m.modelName = "Opus 5.5 1M"; m.effort = "xhigh"
    m.linesAdded = 214; m.linesRemoved = 37; m.branch = "clouding-bar"; m.agents = 2
    let st = WidgetState(); st.mode = .pill
    let host = NSHostingView(rootView: VStack { WidgetView(model: m, state: st); Spacer() }
        .frame(width: 260, height: 560).padding(.top, 20))
    renderView(host, size: NSSize(width: 260, height: 560), name: name)
}
do { // writing in the pill's chat
    let m = sampleModel()
    m.config.taskQueue = true
    let st = WidgetState(); st.mode = .pill; st.pillTyping = true; st.pillDraft = "Проверь тесты и почини что упало"
    let host = NSHostingView(rootView: VStack { WidgetView(model: m, state: st); Spacer() }
        .frame(width: 500, height: 90).padding(.top, 20))
    renderView(host, size: NSSize(width: 500, height: 90), name: "w-pill-typing")
}
do { // edit mode, mid-pull
    let m = sampleModel()
    m.config.metrics = ["model", "lines", "git", "agents"]
    m.modelName = "Opus 5.5 1M"; m.effort = "xhigh"
    let st = WidgetState(); st.mode = .pill; st.pillEditSize = CGSize(width: 520, height: 44)
    let host = NSHostingView(rootView: VStack { WidgetView(model: m, state: st); Spacer() }
        .frame(width: 600, height: 90).padding(.top, 20))
    renderView(host, size: NSSize(width: 600, height: 90), name: "w-pill-editing")
}
// Docked in the notch: drawn (no notch), around a real one, listening, the panel out of it.
for (name, camera, mode, listening) in [("n-drawn", 0.0, WidgetMode.pill, false), ("n-camera", 190.0, .pill, false),
                                        ("n-listening", 190.0, .pill, true), ("n-panel", 190.0, .panel, false)] {
    let m = sampleModel()
    m.config.metrics = ["model", "agents"]; m.modelName = "Opus 5.5 1M"; m.effort = "xhigh"; m.agents = 2
    m.config.taskQueue = true
    if listening { m.listening = true; m.heard = "Перескажи последний ответ коротко" }
    let st = WidgetState(); st.mode = mode; st.notched = true; st.notchWidth = CGFloat(camera); st.notchHeight = camera > 0 ? 34 : 32
    let size = NSSize(width: 720, height: mode == .panel ? 330 : listening ? 140 : 70)
    let host = NSHostingView(rootView: VStack(spacing: 0) { WidgetView(model: m, state: st); Spacer(minLength: 0) }
        .frame(width: size.width, height: size.height))
    renderView(host, size: size, name: name)
}
// The notch pulled wider, writing in it, and Claude's requests coming out of it.
for (name, camera, notchWidth, notchHeight) in [("n-wide-drawn", 0.0, 640.0, 0.0), ("n-wide-camera", 190.0, 760.0, 0.0),
                                                ("n-wide-rows", 190.0, 560.0, 90.0)] {
    let m = sampleModel()
    m.config.metrics = ["model", "agents"]; m.modelName = "Opus 5.5 1M"; m.effort = "xhigh"; m.agents = 2
    m.config.taskQueue = true
    m.config.notchWidth = notchWidth; m.config.notchHeight = notchHeight
    let st = WidgetState(); st.mode = .pill; st.notched = true; st.notchWidth = CGFloat(camera); st.notchHeight = 34
    let size = NSSize(width: 900, height: 130)
    let host = NSHostingView(rootView: VStack(spacing: 0) { WidgetView(model: m, state: st); Spacer(minLength: 0) }
        .frame(width: size.width, height: size.height))
    renderView(host, size: size, name: name)
}
for (name, camera) in [("n-typing-drawn", 0.0), ("n-typing-camera", 190.0)] {
    let m = sampleModel()
    m.config.taskQueue = true
    let st = WidgetState(); st.mode = .pill; st.notched = true; st.notchWidth = CGFloat(camera); st.notchHeight = 34
    st.pillTyping = true; st.pillDraft = "Проверь тесты и почини что упало"
    let host = NSHostingView(rootView: VStack(spacing: 0) { WidgetView(model: m, state: st); Spacer(minLength: 0) }
        .frame(width: 720, height: 110))
    renderView(host, size: NSSize(width: 720, height: 110), name: name)
}
for (name, question) in [("n-permission", false), ("n-question", true)] {
    let m = sampleModel()
    if question {
        var card = AppModel.RequestCard(id: UUID(), kind: .question, project: "DiaRoute")
        card.question = "Which storage should offline routes use?"
        card.options = ["SQLite (Recommended)", "MMKV", "AsyncStorage"]
        card.descriptions = ["Queries by date and area", "Fast key-value, small data", "Simplest, slowest"]
        m.request = card
        m.otherDraft = "WatermelonDB, sync later"
    } else {
        m.request = .init(id: UUID(), kind: .permission, project: "DiaRoute", verb: "Run", detail: "npm run build && npm test")
    }
    let st = WidgetState(); st.mode = .panel; st.notched = true; st.notchWidth = 0; st.notchHeight = 32
    let size = NSSize(width: 720, height: question ? 470 : 260)
    let host = NSHostingView(rootView: VStack(spacing: 0) { WidgetView(model: m, state: st); Spacer(minLength: 0) }
        .frame(width: size.width, height: size.height))
    renderView(host, size: size, name: name)
}
// The notch grown: a question, an OK, and the same around a real camera.
for (name, camera, question) in [("n-grown-ask", 0.0, true), ("n-grown-ok", 0.0, false), ("n-grown-ask-camera", 190.0, true)] {
    let m = sampleModel()
    if question {
        var card = AppModel.RequestCard(id: UUID(), kind: .question, project: "DiaRoute")
        card.question = "Which storage should offline routes use? They need queries by date and area."
        card.options = ["SQLite (Recommended)", "MMKV", "AsyncStorage", "WatermelonDB"]
        card.index = 0; card.count = 2
        m.request = card
    } else {
        m.request = .init(id: UUID(), kind: .permission, project: "DiaRoute", verb: "Run", detail: "npm run build && npm test -- --watch=false")
    }
    let st = WidgetState(); st.mode = .pill; st.notched = true; st.notchWidth = CGFloat(camera); st.notchHeight = camera > 0 ? 34 : 32
    let host = NSHostingView(rootView: VStack(spacing: 0) { WidgetView(model: m, state: st); Spacer(minLength: 0) }
        .frame(width: 720, height: 230))
    renderView(host, size: NSSize(width: 720, height: 230), name: name)
}
do { // everything optional switched off but a few
    let m = sampleModel()
    m.config.widgetHides = ["session", "mic", "buttons"]; m.config.pillShows = ["context"]
    m.config.metrics = ["model"]; m.modelName = "Opus 5.5 1M"; m.effort = "xhigh"; m.config.pillWidth = 10_000
    m.buttons = []
    let st = WidgetState(); st.mode = .pill
    let host = NSHostingView(rootView: VStack { WidgetView(model: m, state: st); Spacer() }.frame(width: 500, height: 80).padding(.top, 10))
    renderView(host, size: NSSize(width: 500, height: 80), name: "w-pill-hides")
    let st2 = WidgetState(); st2.mode = .panel
    let host2 = NSHostingView(rootView: VStack { WidgetView(model: m, state: st2); Spacer() }.frame(width: 500, height: 200).padding(.top, 10))
    renderView(host2, size: NSSize(width: 500, height: 200), name: "w-panel-hides")
}
for (name, lift, hop) in [("d-hop", 0.0, 16.0), ("d-lift", 0.4, 0.0), ("d-island", 1.0, 0.0)] {
    let m = sampleModel()
    let st = WidgetState(); st.mode = .panel; st.hidesHeaderCharacter = true
    let a = DrawerAnimation(); a.rise = 0; a.hop = CGFloat(hop); a.lift = CGFloat(lift); a.awake = true
    a.panelHeight = NSHostingView(rootView: WidgetView(model: m, state: st)).fittingSize.height
    let host = NSHostingView(rootView: DrawerView(model: m, state: st, anim: a, drag: { _ in })
        .frame(width: 440, height: 260))
    renderView(host, size: NSSize(width: 440, height: 260), name: name)
}
widget("w-chats", .chats, size: NSSize(width: 480, height: 400))
do { // the Chats tab, a chat's composer open: words, a screenshot for it, one queued, the note after Send
    let m = sampleModel()
    m.chatDrafts = ["2": "Check the form on mobile too"]
    m.chatFiles = ["2": ["/Users/me/.cloudingbar/shots/shot-2026-10-27T15-02-11Z.png"]]
    m.queue = [.init(text: "Run the tests and fix what fails", sessionId: "2", project: "bots")]
    m.sentNote = .init(chat: "2", text: "Queued for Lead bot — goes when you open it")
    let st = WidgetState(); st.mode = .chats; st.composerChat = "2"
    let host = NSHostingView(rootView: VStack { WidgetView(model: m, state: st); Spacer() }
        .frame(width: 480, height: 520).padding(.top, 20))
    renderView(host, size: NSSize(width: 480, height: 520), name: "w-chats-composer")
    let st2 = WidgetState(); st2.mode = .chats; st2.composerChat = "5"
    m.listeningFor = "5"; m.heard = "Перескажи последний ответ коротко"; m.sentNote = nil
    let host2 = NSHostingView(rootView: VStack { WidgetView(model: m, state: st2); Spacer() }
        .frame(width: 480, height: 480).padding(.top, 20))
    renderView(host2, size: NSSize(width: 480, height: 480), name: "w-chats-listening")
}
widget("w-empty", .panel, size: NSSize(width: 400, height: 320)) {
    $0.hasSession = false; $0.sessionPercent = 20; $0.limitAge = "2 h ago"
}
// A fresh install with no chat seen yet: what's switched on shows, "—" where nothing's known.
func noChat(_ m: AppModel) -> AppModel {
    let fresh = AppModel()
    fresh.config = m.config
    fresh.config.metrics = ["git", "lines", "time", "model", "agents"]
    fresh.config.pillShows = ["context", "reset", "cost"]
    fresh.config.screenshot = true
    fresh.config.taskQueue = true
    fresh.config.pillWidth = 700
    fresh.buttons = Config().effectiveButtons
    fresh.sessionPercent = 6
    fresh.pluginActive = true
    return fresh
}
for (name, mode, size) in [("w-nochat-pill", WidgetMode.pill, NSSize(width: 760, height: 120)),
                           ("w-nochat-panel", .panel, NSSize(width: 720, height: 360))] {
    let m = noChat(sampleModel())
    let state = WidgetState()
    state.mode = mode
    renderView(NSHostingView(rootView: VStack { WidgetView(model: m, state: state); Spacer() }
        .frame(width: size.width, height: size.height).padding(.top, 20)), size: size, name: name)
}
widget("w-panel-model", .panel, size: NSSize(width: 720, height: 300)) {
    $0.config.metrics = ["model", "lines", "git", "agents"]
    $0.config.taskQueue = true
    $0.modelName = "Opus 5.5 1M"; $0.modelId = "claude-opus-5-5[1m]"; $0.effort = "xhigh"
    $0.linesAdded = 214; $0.linesRemoved = 37; $0.branch = "clouding-bar"; $0.agents = 2
    $0.pickingModel = true
}
widget("w-panel-agents", .panel, size: NSSize(width: 720, height: 450)) {
    $0.config.metrics = ["model", "agents"]
    $0.config.taskQueue = true
    $0.modelName = "Opus 5.5 1M"; $0.effort = "xhigh"; $0.agents = 3
    $0.agentRows = [
        .init(id: "1", type: "Explore", task: "Find where hooks are installed", doing: "Read · install.sh", elapsed: "40 s", background: false),
        .init(id: "2", type: "general-purpose", task: "Check the transcripts for /model", doing: "Bash · grep -rl \"Set model to\" ~/.claude/projects",
              elapsed: "2 min", background: true),
        .init(id: "3", type: "Plan", task: "Design the subagents list", doing: nil, elapsed: "3 s", background: false),
    ]
    $0.showingAgents = true
}
widget("w-panel-files-insert", .panel, size: NSSize(width: 720, height: 260)) {
    $0.attachments = ["/Users/me/Desktop/Снимок экрана 2026-10-19.png", "/Users/me/DiaRoute/docs/offline-routes.pdf"]
    $0.chatInFront = true
}
widget("w-panel-files", .panel, size: NSSize(width: 720, height: 300)) {
    $0.config.taskQueue = true
    $0.attachments = ["/Users/me/Desktop/Снимок экрана 2026-10-19.png", "/Users/me/DiaRoute/docs/offline-routes.pdf", "/Users/me/DiaRoute/src"]
    $0.chatInFront = true
}
do { // files dragged over the open panel
    let m = sampleModel()
    m.config.taskQueue = true
    let st = WidgetState(); st.mode = .panel; st.dropHover = true
    let host = NSHostingView(rootView: VStack { WidgetView(model: m, state: st); Spacer() }
        .frame(width: 480, height: 230).padding(.top, 20))
    renderView(host, size: NSSize(width: 480, height: 230), name: "w-panel-drop")
}
for (name, hover) in [("w-pill-drop", true), ("w-pill-files", false)] {
    let m = sampleModel()
    m.attachments = ["/tmp/a.png", "/tmp/b.pdf"]
    let st = WidgetState(); st.mode = .pill; st.dropHover = hover
    let host = NSHostingView(rootView: VStack { WidgetView(model: m, state: st); Spacer() }
        .frame(width: 400, height: 90).padding(.top, 20))
    renderView(host, size: NSSize(width: 400, height: 90), name: name)
}
do { // writing in the pill with files attached
    let m = sampleModel()
    m.config.taskQueue = true
    m.attachments = ["/tmp/a.png", "/tmp/b.pdf"]
    let st = WidgetState(); st.mode = .pill; st.pillTyping = true
    let host = NSHostingView(rootView: VStack { WidgetView(model: m, state: st); Spacer() }
        .frame(width: 500, height: 90).padding(.top, 20))
    renderView(host, size: NSSize(width: 500, height: 90), name: "w-pill-typing-files")
}
do { // the Touch Bar tab with everything on, and the model known
    let m = sampleModel()
    m.touchBarPresent = true
    m.config.touchBarShows = ["session", "reset", "context", "model", "agents", "buttons", "shot", "mic"]
    m.modelName = "Opus 5.5 1M"; m.effort = "xhigh"; m.agents = 2
    let host = NSHostingView(rootView: SettingsView(model: m, tab: "touchbar"))
    renderView(host, size: NSSize(width: SettingsView.width, height: 560), name: "s-touchbar-all")
}
do { // Settings' copy of the widget while Claude asks: the widget, never the request (its keys would answer)
    let m = sampleModel()
    m.request = .init(id: UUID(), kind: .permission, project: "DiaRoute", verb: "Run", detail: "rm -rf build")
    let host = NSHostingView(rootView: SettingsView(model: m, tab: "widget"))
    renderView(host, size: NSSize(width: SettingsView.width, height: 560), name: "s-widget-request")
}
do { // a fresh install, no chat open: the widget's copy in Settings shows example numbers, every item switched on
    let m = AppModel()
    m.config.metrics = ["model", "time", "lines", "git", "agents"]
    m.config.pillShows = ["context", "reset", "cost"]
    m.config.screenshot = true
    m.buttons = Config().effectiveButtons
    let host = NSHostingView(rootView: SettingsView(model: m, tab: "widget"))
    renderView(host, size: NSSize(width: SettingsView.width, height: 560), name: "s-widget-nochat")
}
// Every More… starts closed, as on a first run; the *-more renders open them.
let generalGroups = ["App", "Connections", "Context"]
let moreKeys = ["app", "connections", "context", "widget", "shows", "touchbar", "stats"]
for k in moreKeys { UserDefaults.standard.removeObject(forKey: "settings.more." + k) }
for tab in ["general", "widget", "touchbar", "buttons", "stats"] {
    let m = sampleModel()
    m.touchBarPresent = true
    m.knownProjects = ["DiaRoute", "bots"]
    if tab == "general" { m.voiceOffline = false; m.config.voiceLanguage = "uk-UA" }
    if tab == "stats" { m.weekPercent = 23; m.weekReset = "Thu 14:00" }
    if tab == "general" { // claude.ai signed in: Cowork's row in Connections
        m.hasLiveKey = true; m.liveLimitState = "On"
    }
    m.hasNotch = tab == "widget"
    let host = NSHostingView(rootView: SettingsView(model: m, tab: tab))
    renderView(host, size: NSSize(width: SettingsView.width, height: 560), name: "s-\(tab)")
    if tab == "general" { // grey buttons
        let mg = m
        mg.config.buttonColors = "gray"
        renderView(NSHostingView(rootView: SettingsView(model: mg, tab: tab)), size: NSSize(width: SettingsView.width, height: 560),
                   name: "s-general-gray")
        mg.config.buttonColors = "color"
    }
    if ["general", "widget", "touchbar"].contains(tab) { // every More… open, the tab alone at its full height
        for k in moreKeys { UserDefaults.standard.set(true, forKey: "settings.more." + k) }
        for g in generalGroups { SettingsFolds.shared.show(g) } // General's groups are folded by default
        let tabOnly = Group {
            if tab == "general" { GeneralTab(model: m) } else if tab == "widget" { WidgetTab(model: m) } else { TouchBarTab(model: m) }
        }
        .padding(.leading, SettingsCloud.gutter).padding(.trailing, 18).padding(.vertical, 16)
        .frame(width: SettingsView.width, alignment: .top).background(Color.sBackground)
        let height = NSHostingView(rootView: tabOnly).fittingSize.height
        renderView(NSHostingView(rootView: tabOnly), size: NSSize(width: SettingsView.width, height: ceil(height)), name: "s-\(tab)-more")
        if tab == "general" { // asked for by name: Connections, not signed in, Accessibility off
            let mc = sampleModel()
            mc.accessibilityTrusted = false
            renderView(NSHostingView(rootView: SettingsView(model: mc, tab: "cowork")), size: NSSize(width: SettingsView.width, height: 560),
                       name: "s-cowork-request")
        }
        for k in moreKeys { UserDefaults.standard.removeObject(forKey: "settings.more." + k) }
        SettingsFolds.shared.reset()
    }
    if tab == "general" { // one group opened out of the folded rest (owner, 27.10), dark and light
        SettingsFolds.shared.show("App")
        renderView(NSHostingView(rootView: SettingsView(model: m, tab: tab)), size: NSSize(width: SettingsView.width, height: 560), name: "s-general-open")
        renderView(NSHostingView(rootView: SettingsView(model: m, tab: tab)), size: NSSize(width: SettingsView.width, height: 560),
                   name: "s-general-open-light", light: true)
        SettingsFolds.shared.show("Connections")
        renderView(NSHostingView(rootView: SettingsView(model: m, tab: tab)), size: NSSize(width: SettingsView.width, height: 560), name: "s-general-open2")
        SettingsFolds.shared.reset()
    }
    if tab == "stats" { // all of it, More open
        UserDefaults.standard.set(true, forKey: "settings.more.stats")
        let tabOnly = StatsTab(model: m).padding(.leading, SettingsCloud.gutter).padding(.trailing, 18).padding(.vertical, 16)
            .frame(width: SettingsView.width, alignment: .top).background(Color.sBackground)
        renderView(NSHostingView(rootView: tabOnly), size: NSSize(width: SettingsView.width, height: 1240), name: "s-stats-full")
        UserDefaults.standard.removeObject(forKey: "settings.more.stats")
    }
    if ["general", "widget", "stats"].contains(tab) {
        let light = NSHostingView(rootView: SettingsView(model: m, tab: tab))
        renderView(light, size: NSSize(width: SettingsView.width, height: 560), name: "s-\(tab)-light", light: true)
    }
}

// The tour in the settings window, at a few of its stops.
for step in SettingsTour.stops.indices {
    let m = sampleModel()
    m.touchBarPresent = true
    m.hasNotch = true
    m.tourStep = step
    let host = NSHostingView(rootView: SettingsView(model: m, tab: SettingsTour.stops[step].tab))
    renderView(host, size: NSSize(width: SettingsView.width, height: 560),
               name: SettingsTour.stops[step].tab == "stats" ? "s-stats-tour-\(step)" : "tour-\(step)")
}

do { // Cloud's faces: awake, happy, dizzy, shy
    let row = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 110))
    for (i, face) in ["awake", "happy", "dizzy", "shy"].enumerated() {
        let v = MascotView(size: 80)
        v.frame = NSRect(x: 15 + CGFloat(i) * 95, y: 15, width: 80, height: 80)
        v.awake = true
        if face == "happy" { v.poke() }
        if face == "dizzy" { for _ in 0..<5 { v.poke() } }
        if face == "shy" { v.shy = true }
        row.addSubview(v)
    }
    // Happy lasts 1.1 s, past the render's wait: poke it again just before.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { (row.subviews[1] as? MascotView)?.poke() }
    renderView(row, size: row.frame.size, name: "m-faces")
}

do { // the ten Clouds, one per chat colour (owner, 27.10): 28 pt as on the bar, and big; awake, asleep, waiting
    func sheet(_ name: String, moods: [(String, (MascotView) -> Void)]) {
        let cell: CGFloat = 92, rowHeights: [CGFloat] = [36, 92]
        let height = CGFloat(moods.count) * (rowHeights[0] + rowHeights[1]) + 8
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: cell * 10 + 12, height: height))
        var top: CGFloat = 4
        for (_, setup) in moods {
            for (r, size) in [CGFloat(28), 80].enumerated() {
                for i in 0..<10 {
                    let v = MascotView(size: size)
                    v.variant = i
                    setup(v)
                    v.frame = NSRect(x: 6 + CGFloat(i) * cell + (cell - size) / 2, y: height - top - rowHeights[r] + (rowHeights[r] - size) / 2,
                                     width: size, height: size)
                    sheet.addSubview(v)
                }
                top += rowHeights[r]
            }
        }
        renderView(sheet, size: sheet.frame.size, name: name)
    }
    sheet("m-clouds", moods: [("awake", { $0.awake = true }), ("sleep", { _ in }), ("wait", { $0.activity = .wait })])
    sheet("m-clouds-more", moods: [("work", { $0.activity = .work }), ("shy", { $0.shy = true }),
                                    ("dizzy", { v in for _ in 0..<5 { v.poke() } })])
}


// Everything stacked in one sheet, 12 px apart on grey, for a quick look.
let sheetWidth = images.map(\.width).max() ?? 0
let sheetHeight = images.reduce(0) { $0 + $1.height + 12 }
if let ctx = CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
    ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
    var y = sheetHeight
    for image in images {
        y -= image.height + 12
        ctx.draw(image, in: CGRect(x: 0, y: y + 6, width: image.width, height: image.height))
    }
    if let sheet = ctx.makeImage() {
        let rep = NSBitmapImageRep(cgImage: sheet)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("all.png"))
    }
}
print(out.appendingPathComponent("all.png").path)

extension CALayer {
    func removeAllAnimationsRecursively() {
        removeAllAnimations()
        sublayers?.forEach { $0.removeAllAnimationsRecursively() }
    }
}
