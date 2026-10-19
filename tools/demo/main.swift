import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Records the tour's scenes as they play — the notch answering a question,
// the pill pulled wider, the Touch Bar asking — into docs/demo.gif for the
// README. Opens a small window in a corner of the screen for ~20 s and
// captures its own pixels at 12 fps. Usage: demo <out.gif>
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/demo.gif")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let director = TourDirector()
let size = TourDirector.stage
struct Stage: View {
    @ObservedObject var director: TourDirector
    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch director.page {
                case 4: TourBar(director: director)
                default:
                    WidgetView(model: director.model, state: director.state)
                        .padding(.top, director.page == 1 ? TourDirector.pillTop : director.page == 3 ? 16 : 0)
                }
            }
            .frame(width: TourDirector.stage.width, height: TourDirector.stage.height, alignment: .top)
            TourPointer(director: director)
        }
        .frame(width: TourDirector.stage.width, height: TourDirector.stage.height)
        .background(LinearGradient(colors: [Color(hex: 0x1B1B1D), Color(hex: 0x2A2A2E)], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }
}

let window = NSWindow(contentRect: NSRect(x: 40, y: 60, width: size.width, height: size.height),
                      styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = NSHostingView(rootView: Stage(director: director))
window.level = .floating
window.appearance = NSAppearance(named: .darkAqua)
window.orderFrontRegardless()

// The scenes, one after another: (page, seconds).
let reel: [(Int, Double)] = [(2, 9.4), (1, 7.2), (4, 8.2)]
var frames: [CGImage] = []
let fps = 12.0
var t0 = Date()

func record(_ i: Int) {
    guard i < reel.count else { finish(); return }
    let (page, seconds) = reel[i]
    director.play(page)
    t0 = Date()
    Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { timer in
        let id = CGWindowID(window.windowNumber)
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) {
            frames.append(image)
        }
        if Date().timeIntervalSince(t0) >= seconds {
            timer.invalidate()
            record(i + 1)
        }
    }
}

func finish() {
    director.stop()
    window.orderOut(nil)
    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { exit(1) }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                 kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
    for f in frames { CGImageDestinationAddImage(dest, f, props) }
    CGImageDestinationFinalize(dest)
    print("\(frames.count) frames → \(out.path)")
    exit(0)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { record(0) }
app.run()
