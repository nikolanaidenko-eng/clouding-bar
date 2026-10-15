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
    RunLoop.main.run(until: Date().addingTimeInterval(1.2)) // let appear animations finish
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
        .init(id: "1", name: "DiaRoute", status: "Needs your OK", activity: .wait, context: 31, waiting: true),
        .init(id: "2", name: "bots", status: "Working · 2 min", activity: .work, context: 58, waiting: false),
        .init(id: "3", name: "agent-office", status: "Working · 9 min", activity: .work, context: 83, waiting: false),
        .init(id: "4", name: "claudebar", status: "Idle · 12 min", activity: .sleep, context: 94, waiting: false),
        .init(id: "5", name: "landing", status: "Idle · 1 h", activity: .sleep, context: 12, waiting: false),
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
widget("w-panel", .panel)
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
widget("w-sessions", .sessions)
widget("w-empty", .panel, size: NSSize(width: 400, height: 320)) {
    $0.hasSession = false; $0.sessionPercent = 20; $0.limitAge = "2 h ago"
}
for tab in ["general", "buttons"] {
    let m = sampleModel()
    m.touchBarPresent = true
    m.knownProjects = ["DiaRoute", "bots"]
    if tab == "general" { m.voiceOffline = false; m.config.voiceLanguage = "uk-UA" }
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
