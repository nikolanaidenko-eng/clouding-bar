import SwiftUI

/// The Stats tab from design/Settings.dc.html: the week's headline, a
/// days × hours heat map (grey shades, orange where the limit was hit, a
/// wave as it appears) and each project's share.
struct StatsTab: View {
    @State private var stats: WeekStats?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let stats {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats.headline).font(.system(size: 20, weight: .semibold))
                    Text(subtitle(stats)).font(.system(size: 12)).foregroundColor(.cbSecondary)
                }
                heatMap(stats)
                if !stats.projects.isEmpty { projects(stats) }
                Text(today(stats)).font(.system(size: 11)).foregroundColor(.cbSecondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading this week's sessions…").font(.system(size: 12)).foregroundColor(.cbSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: load)
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = StatsBuilder.build()
            DispatchQueue.main.async {
                stats = s
                if reduceMotion { shown = true } else { DispatchQueue.main.async { shown = true } }
            }
        }
    }

    private func subtitle(_ s: WeekStats) -> String {
        ["Claude's usage limit resets every 5 hours", s.busiest, s.limitHours.isEmpty ? nil : "orange: hours at the limit"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The heat map fills the tab: 24 hours across, the days' names before.
    private static let labelWidth: CGFloat = 26, cellGap: CGFloat = 3
    private static var cell: CGFloat {
        let inner = SettingsView.width - 36 // the tab's padding
        return floor((inner - labelWidth - cellGap - 23 * cellGap) / 24)
    }

    private func heatMap(_ s: WeekStats) -> some View {
        let peak = max(1, s.grid.flatMap { $0 }.max() ?? 1)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEE"
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: Self.cellGap) {
                    Text(fmt.string(from: s.days[d])).font(.system(size: 10)).foregroundColor(.cbSecondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color(s, d, h, peak))
                            .frame(width: Self.cell, height: 16)
                            .scaleEffect(shown ? 1 : 0.4)
                            .opacity(shown ? 1 : 0)
                            .animation(.cb(0.26).delay(Double(h * 12 + d * 8) / 1000), value: shown)
                    }
                }
            }
            HStack {
                ForEach(["0:00", "6:00", "12:00", "18:00", "23:00"], id: \.self) { t in
                    Text(t)
                    if t != "23:00" { Spacer() }
                }
            }
            .font(.system(size: 10)).foregroundColor(.cbSecondary)
            .padding(.leading, Self.labelWidth + Self.cellGap)
            .frame(width: Self.labelWidth + Self.cellGap + 24 * (Self.cell + Self.cellGap) - Self.cellGap)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heat map of Claude Code use by day and hour")
    }

    private func color(_ s: WeekStats, _ d: Int, _ h: Int, _ peak: Int) -> Color {
        if s.limitHours.contains(d * 24 + h) { return .cbWarning }
        let v = Double(s.grid[d][h]) / Double(peak)
        return v < 0.05 ? Color.white.opacity(0.05) : Color.white.opacity(0.12 + v * 0.7)
    }

    private func projects(_ s: WeekStats) -> some View {
        let shades = [Color(hex: 0xE5E5EA), Color(hex: 0xAEAEB2), Color(hex: 0x636366), Color(hex: 0x3A3A3C)]
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(s.projects.enumerated()), id: \.offset) { i, p in
                        Rectangle().fill(shades[min(i, 3)])
                            .frame(width: max(2, (geo.size.width - CGFloat(s.projects.count - 1) * 2) * p.share))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 16) {
                ForEach(Array(s.projects.enumerated()), id: \.offset) { _, p in
                    (Text(p.name).foregroundColor(p.name == "other" ? .cbSecondary : .cbText)
                        + Text(" \(Int((p.share * 100).rounded()))%").foregroundColor(.cbSecondary))
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func today(_ s: WeekStats) -> String {
        var parts = ["Today: \(s.todaySessions) session\(s.todaySessions == 1 ? "" : "s")"]
        if !s.todayProjects.isEmpty { parts.append(s.todayProjects.prefix(4).joined(separator: ", ")) }
        if let p = s.todayPeak { parts.append("limit peaked at \(Int(p.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}
