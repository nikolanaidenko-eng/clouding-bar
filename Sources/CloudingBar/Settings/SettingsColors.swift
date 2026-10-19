import AppKit
import SwiftUI

/// The settings window's colours, light and dark (owner's request, 20.10).
/// They follow the window's appearance: Settings → General → Appearance,
/// or the system's. The widget stays dark whatever this says.
extension Color {
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static let sBackground = adaptive(light: 0xF2F2F5, dark: 0x232325)
    static let sText = adaptive(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let sSecondary = adaptive(light: 0x636366, dark: 0xA1A1A6)
    static let sMuted = adaptive(light: 0x707075, dark: 0x8E8E93)
    /// A rounded box of rows.
    static let sGroup = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.05)
    static let sLine = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.07)
    /// Behind a segmented control.
    static let sTrack = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.06, darkAlpha: 0.3)
    /// A small control's fill (the ? button, a count).
    static let sControl = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.1)
    static let sSwitchOff = adaptive(light: 0xDCDCE0, dark: 0x48484A)
    static let sChipOff = adaptive(light: 0xC7C7CC, dark: 0x636366)
    static let sField = adaptive(light: 0xFFFFFF, dark: 0x000000, lightAlpha: 1, darkAlpha: 0.25)
    static let sFieldLine = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.18)
    static let sAccent = Color(hex: 0x0A84FF)
    /// Bars and lines of the charts.
    static let sChart = adaptive(light: 0x0A84FF, dark: 0x64A8FF)
    static let sMeterTrack = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.12)

    /// A limit's bar: blue, orange from 70%, red from 90%.
    static func sMeter(_ percent: Double?) -> Color {
        let p = percent ?? 0
        return p >= 90 ? Color(hex: 0xFF453A) : p >= 70 ? .cbWarning : .sChart
    }
}

extension NSColor {
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
}

/// A section's little coloured icon, as in System Settings.
struct SectionIcon: View {
    let symbol: String
    let tint: UInt32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: tint)))
            .accessibilityHidden(true)
    }
}
