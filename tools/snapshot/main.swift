import AppKit

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
