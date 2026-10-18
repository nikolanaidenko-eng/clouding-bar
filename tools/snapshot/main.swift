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

func renderView(_ view: NSView, size: NSSize, name: String) {
    let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = NSColor(hex: 0x1B1B1D).cgColor
    view.frame = NSRect(origin: .zero, size: size)
    backdrop.addSubview(view)
    let window = NSWindow(contentRect: backdrop.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = backdrop
    backdrop.layoutSubtreeIfNeeded()
    backdrop.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(name == "s-stats" ? 4 : 1.2)) // animations, stats
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
    m.config.sessionsList = true
    m.hasSession = true
    m.activity = .work
    m.project = "DiaRoute"
    m.sessionPercent = 42
    m.resetShort = "1:23"
    m.resetLong = "1 h 23 min"
    m.contextPercent = 31
    m.tokensIn = 41_200
    m.tokensOut = 2_300
    m.buttons = Config().effectiveButtons
    m.sessions = [
        .init(id: "1", name: "DiaRoute", status: "VS Code · Needs your OK", activity: .wait, context: 31, waiting: true),
        .init(id: "2", name: "bots", status: "Cowork · Working · 2 min", activity: .work, context: 58, waiting: false),
        .init(id: "3", name: "agent-office", status: "VS Code · Working · 9 min", activity: .work, context: 83, waiting: false),
        .init(id: "4", name: "claudebar", status: "Terminal · Idle · 12 min", activity: .sleep, context: 94, waiting: false),
        .init(id: "5", name: "landing", status: "VS Code · Idle · 1 h", activity: .sleep, context: 12, waiting: false),
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

widget("w-strip", .strip, size: NSSize(width: 200, height: 60))
widget("w-pill", .pill, size: NSSize(width: 400, height: 90))
widget("w-pill-cost", .pill, size: NSSize(width: 400, height: 90)) { $0.config.pillShows = ["context", "reset", "cost"]; $0.cost = 0.84 }
widget("w-pill-minimal", .pill, size: NSSize(width: 400, height: 90)) { $0.hasSession = false; $0.activity = .sleep }
widget("w-pill-request", .pill, size: NSSize(width: 400, height: 90)) {
    $0.request = .init(id: UUID(), kind: .permission, project: "DiaRoute", verb: "Run", detail: "npm run build && npm test")
}
widget("w-pill-listening", .pill, size: NSSize(width: 400, height: 90)) { $0.listening = true; $0.heard = "Перескажи последний ответ" }
widget("w-panel", .panel, size: NSSize(width: 480, height: 220))
widget("w-permission", .panel, size: NSSize(width: 480, height: 200)) {
    $0.request = .init(id: UUID(), kind: .permission, project: "DiaRoute", verb: "Run", detail: "npm run build && npm test")
}
widget("w-question", .panel) {
    var card = AppModel.RequestCard(id: UUID(), kind: .question, project: "DiaRoute")
    card.question = "Which storage should offline routes use?"
    card.options = ["SQLite (Recommended)", "MMKV", "AsyncStorage"]
    card.descriptions = ["Queries by date and area", "Fast key-value, small data", "Simplest, slowest"]
    card.index = 0
    card.count = 2
    $0.request = card
    $0.otherDraft = "WatermelonDB, sync later"
}
widget("w-panel-extras", .panel, size: NSSize(width: 720, height: 330)) {
    $0.config.metrics = ["model", "lines", "git", "agents"]
    $0.config.templatesEnabled = true
    $0.config.screenshot = true
    $0.config.taskQueue = true
    $0.modelName = "Opus 5.5 1M"; $0.effort = "xhigh"
    $0.linesAdded = 214; $0.linesRemoved = 37; $0.branch = "clouding-bar"; $0.agents = 2
    $0.queue = [.init(text: "Run the tests and fix what fails", sessionId: nil, project: nil),
                .init(text: "Update the README", sessionId: nil, project: nil)]
}
widget("w-panel-all", .panel, size: NSSize(width: 720, height: 360)) {
    $0.config.metrics = ["model", "lines", "git", "agents"]
    $0.config.templatesEnabled = true
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
for (name, width, height) in [("w-pill-column", 64.0, 520.0), ("w-pill-column-wide", 190.0, 520.0)] {
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
for (name, lift, hop) in [("d-hop", 0.0, 16.0), ("d-lift", 0.4, 0.0), ("d-island", 1.0, 0.0)] {
    let m = sampleModel()
    let st = WidgetState(); st.mode = .panel; st.hidesHeaderCharacter = true
    let a = DrawerAnimation(); a.rise = 0; a.hop = CGFloat(hop); a.lift = CGFloat(lift); a.awake = true
    a.panelHeight = NSHostingView(rootView: WidgetView(model: m, state: st)).fittingSize.height
    let host = NSHostingView(rootView: DrawerView(model: m, state: st, anim: a, drag: { _ in })
        .frame(width: 440, height: 260))
    renderView(host, size: NSSize(width: 440, height: 260), name: name)
}
widget("w-sessions", .sessions)
widget("w-empty", .panel, size: NSSize(width: 400, height: 320)) {
    $0.hasSession = false; $0.sessionPercent = 20; $0.limitAge = "2 h ago"
}
for tab in ["general", "buttons", "cowork", "stats"] {
    let m = sampleModel()
    m.touchBarPresent = true
    m.knownProjects = ["DiaRoute", "bots"]
    if tab == "general" { m.voiceOffline = false; m.config.voiceLanguage = "uk-UA" }
    if tab == "cowork" {
        m.config.coworkMode = "thresholds"; m.config.coworkFolder = NSHomeDirectory() + "/Documents/Cowork"
        m.coworkLast = "4 min ago · DiaRoute 31%"
    }
    let host = NSHostingView(rootView: SettingsView(model: m, tab: tab))
    renderView(host, size: NSSize(width: 560, height: 560), name: "s-\(tab)")
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
