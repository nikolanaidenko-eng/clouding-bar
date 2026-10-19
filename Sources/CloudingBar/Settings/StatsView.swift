import SwiftUI

/// The Stats tab: both limits now (the 5-hour one with its last 24 hours),
/// the week as a days × hours heat map (orange where the limit was hit),
/// then a few short lines — tokens, models, projects, active time, tools.
struct StatsTab: View {
    @ObservedObject var model: AppModel
    @State private var stats: WeekStats?
    @State private var shown = false
    /// The heat map's square under the pointer: day and hour.
    @State private var hovered: (d: Int, h: Int)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            limits.tourAnchor("stats.limits")
            if let stats {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stats.headline).font(.system(size: 17, weight: .semibold))
                        Text(subtitle(stats)).font(.system(size: 11)).foregroundColor(.sSecondary)
                    }
                    heatMap(stats).tourAnchor("stats.map")
                    hoverLine(stats)
                }
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Where the time went").font(.system(size: 17, weight: .semibold))
                        Text("How long Claude worked this week, and on what. More has tokens, models and tools")
                            .font(.system(size: 11)).foregroundColor(.sSecondary)
                    }
                    details(stats)
                }
                .tourAnchor("stats.time")
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading this week's sessions…").font(.system(size: 12)).foregroundColor(.sSecondary)
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

    // MARK: Limits

    private var limits: some View {
        let week = model.weekPercent.map { (percent: $0, note: model.weekReset.map { "Resets \($0)" } ?? "") }
            ?? LimitHistory.latestWeek().flatMap { s in
                Date().timeIntervalSince(s.time) < 24 * 3600
                    ? (percent: s.percent, note: "From Claude Desktop, \(AppModel.ago(s.time))") : nil
            }
        return HStack(alignment: .top, spacing: 12) {
            card("5-hour limit", model.sessionPercent,
                 model.resetLong.map { "Resets in \($0)" } ?? model.limitAge.map { "Last seen \($0)" } ?? "Not reported yet") {
                sparkline(stats?.limitLine ?? [])
            }
            card("Weekly limit", week?.percent,
                 week?.note ?? "Shows once Claude Code reports it") {
                days(stats)
            }
        }
    }

    /// The week's days as small bars: how much Claude did each day.
    private func days(_ s: WeekStats?) -> some View {
        let totals = s.map { $0.grid.map { $0.reduce(0, +) } } ?? Array(repeating: 0, count: 7)
        let peak = max(1, totals.max() ?? 1)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEEEE"
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<7, id: \.self) { d in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d == 6 ? Color.sAccent : Color.sChart)
                        .frame(height: max(2, 22 * CGFloat(totals[d]) / CGFloat(peak)))
                        .scaleEffect(y: shown ? 1 : 0.1, anchor: .bottom)
                        .animation(.cb(0.5).delay(Double(d) * 0.04), value: shown)
                    Text(s.map { fmt.string(from: $0.days[d]) } ?? "").font(.system(size: 9)).foregroundColor(.sMuted)
                }
                .frame(maxWidth: .infinity)
                .help(s.map { "\(DateFormatter.localizedString(from: $0.days[d], dateStyle: .medium, timeStyle: .none)): \(AppModel.compact(totals[d])) tokens" } ?? "")
            }
        }
        .frame(height: 36, alignment: .bottom)
        .accessibilityLabel("Tokens per day this week")
    }

    private func card<Extra: View>(_ title: String, _ percent: Double?, _ note: String,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11)).foregroundColor(.sSecondary)
                Spacer()
                Text(PillLayout.percent(percent)).font(.system(size: 20, weight: .semibold).monospacedDigit())
            }
            MeterBar(percent: percent, height: 4, track: .sMeterTrack, color: .sMeter(percent))
            Text(note).font(.system(size: 11)).foregroundColor(.sSecondary).lineLimit(1)
            Spacer(minLength: 0)
            extra()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 138, maxHeight: 138, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.sGroup))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.sLine, lineWidth: 0.5))
    }

    /// The 5-hour limit over the last 24 hours, as a small area chart.
    private func sparkline(_ samples: [LimitHistory.Sample]) -> some View {
        GeometryReader { geo in
            let now = Date(), span: Double = 24 * 3600
            let points = samples.map { s -> CGPoint in
                CGPoint(x: geo.size.width * CGFloat(1 - now.timeIntervalSince(s.time) / span),
                        y: geo.size.height * CGFloat(1 - min(100, max(0, s.percent)) / 100))
            }
            ZStack(alignment: .bottomLeading) {
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                    }
                    .fill(LinearGradient(colors: [Color.sChart.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(Color.sChart, lineWidth: 1.4)
                }
                HStack {
                    Text("24 h ago")
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 9)).foregroundColor(.sMuted)
                .offset(y: 12)
            }
        }
        .frame(height: 26)
        .padding(.bottom, 10)
        .accessibilityLabel("The 5-hour limit over the last 24 hours")
    }

    // MARK: Week

    private func subtitle(_ s: WeekStats) -> String {
        ["Each square is an hour: the brighter, the more Claude worked", s.limitHours.isEmpty ? nil : "orange: at the limit"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The heat map fills the tab: 24 hours across, the days' names before.
    private static let labelWidth: CGFloat = 26, cellGap: CGFloat = 3
    private static var cell: CGFloat {
        let inner = SettingsView.width - SettingsCloud.gutter - 18 // the tab's padding
        return floor((inner - labelWidth - cellGap - 23 * cellGap) / 24)
    }

    private func heatMap(_ s: WeekStats) -> some View {
        let peak = max(1, s.grid.flatMap { $0 }.max() ?? 1)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEE"
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: Self.cellGap) {
                    Text(fmt.string(from: s.days[d])).font(.system(size: 10)).foregroundColor(.sSecondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let on = hovered.map { $0.d == d && $0.h == h } ?? false
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(s, d, h, peak))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.sText.opacity(on ? 0.85 : 0), lineWidth: 1.5))
                            .frame(width: Self.cell, height: 13)
                            .scaleEffect(shown ? (on ? 1.25 : 1) : 0.4)
                            .opacity(shown ? 1 : 0)
                            .zIndex(on ? 1 : 0)
                            .animation(.cb(0.26).delay(Double(h * 12 + d * 8) / 1000), value: shown)
                            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
                            .onHover { inside in
                                if inside { hovered = (d, h) } else if on { hovered = nil }
                            }
                    }
                }
            }
            HStack {
                ForEach(["0:00", "6:00", "12:00", "18:00", "23:00"], id: \.self) { t in
                    Text(t)
                    if t != "23:00" { Spacer() }
                }
            }
            .font(.system(size: 10)).foregroundColor(.sSecondary)
            .padding(.leading, Self.labelWidth + Self.cellGap)
            .frame(width: Self.labelWidth + Self.cellGap + 24 * (Self.cell + Self.cellGap) - Self.cellGap)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heat map of Claude Code use by day and hour")
    }

    /// Under the map: the hour and the day under the pointer; else today.
    private func hoverLine(_ s: WeekStats) -> some View {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEEE d MMM"
        let text: Text
        if let at = hovered {
            let tokens = s.grid[at.d][at.h]
            let projects = s.cellProjects[at.d][at.h].sorted { $0.value > $1.value }.prefix(3).map(\.key)
            let hour = [String(format: "%d:00–%d:00", at.h, (at.h + 1) % 24),
                        tokens > 0 ? "\(AppModel.compact(tokens)) tokens" : "nothing",
                        s.cellMinutes[at.d][at.h] > 0 ? "worked \(s.cellMinutes[at.d][at.h]) min" : nil,
                        projects.isEmpty ? nil : projects.joined(separator: ", "),
                        s.cellLimit[at.d][at.h].map { "limit up to \(Int($0.rounded()))%" }]
                .compactMap { $0 }.joined(separator: " · ")
            let dayTokens = s.grid[at.d].reduce(0, +)
            let dayMinutes = s.cellMinutes[at.d].reduce(0, +)
            let day = [fmt.string(from: s.days[at.d]),
                       "\(AppModel.compact(dayTokens)) tokens",
                       dayMinutes > 0 ? "worked \(Self.duration(dayMinutes))" : nil,
                       s.cellLimit[at.d].compactMap { $0 }.max().map { "limit up to \(Int($0.rounded()))%" }]
                .compactMap { $0 }.joined(separator: " · ")
            text = Text(hour).foregroundColor(.sText) + Text("\n" + day).foregroundColor(.sSecondary)
        } else {
            text = Text(today(s)).foregroundColor(.sSecondary)
                + Text("\nPoint at a square to see that hour and day").foregroundColor(.sMuted)
        }
        return text.font(.system(size: 11).monospacedDigit()).lineSpacing(3).lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            .animation(nil, value: hovered.map { $0.d * 24 + $0.h })
    }

    private func color(_ s: WeekStats, _ d: Int, _ h: Int, _ peak: Int) -> Color {
        if s.limitHours.contains(d * 24 + h) { return .cbWarning }
        let v = Double(s.grid[d][h]) / Double(peak)
        return v < 0.05 ? Color.sMeterTrack : Color.sChart.opacity(0.18 + v * 0.82)
    }

    // MARK: Details

    private func details(_ s: WeekStats) -> some View {
        SettingsGroup {
            row("Worked") {
                Text(([Self.duration(s.activeMinutes)] + s.activeByProject.map { "\($0.name) \(Self.duration($0.minutes))" })
                        .joined(separator: " · "))
            }
            if !s.projects.isEmpty { row("Projects") { shares(s.projects) } }
            MoreRows("stats", count: 3) {
                row("Tokens") {
                    Text("\(AppModel.compact(s.weekTokens)) this week · \(AppModel.compact(s.todayTokens)) today")
                        + Text(" · text Claude read and wrote").foregroundColor(.sSecondary)
                }
                if !s.models.isEmpty { row("Models") { shares(s.models) } }
                row("Tools") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.tools.isEmpty ? "—" : s.tools.map { "\($0.name) \($0.count)" }.joined(separator: " · "))
                        Text("\(s.subagents) subagent\(s.subagents == 1 ? "" : "s") started").foregroundColor(.sSecondary)
                    }
                }
            }
        }
    }

    private func row<Content: View>(_ title: String, divider: Bool = true, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundColor(.sSecondary).frame(width: 64, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(divider ? Rectangle().fill(Color.sLine).frame(height: 0.5) : nil, alignment: .bottom)
    }

    /// A thin stacked bar, then each part with its share.
    private func shares(_ list: [(name: String, share: Double)]) -> some View {
        let shades = [Color.sChart, Color(hex: 0xBF5AF2), Color(hex: 0x30B0C7), Color.sChipOff]
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, p in
                        Rectangle().fill(shades[min(i, 3)])
                            .frame(width: max(2, (geo.size.width - CGFloat(list.count - 1) * 2) * p.share))
                    }
                }
            }
            .frame(height: 5)
            .clipShape(RoundedRectangle(cornerRadius: 2.5))
            HStack(spacing: 12) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: 5) {
                        Circle().fill(shades[min(i, 3)]).frame(width: 6, height: 6)
                        (Text(p.name).foregroundColor(p.name == "other" ? .sSecondary : .sText)
                            + Text(" \(Int((p.share * 100).rounded()))%").foregroundColor(.sSecondary))
                    }
                }
            }
            .font(.system(size: 11))
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h" + (minutes % 60 > 0 ? " \(minutes % 60) min" : "") : "\(minutes) min"
    }

    private func today(_ s: WeekStats) -> String {
        var parts = ["Today: \(s.todaySessions) session\(s.todaySessions == 1 ? "" : "s")"]
        if !s.todayProjects.isEmpty { parts.append(s.todayProjects.prefix(4).joined(separator: ", ")) }
        if let p = s.todayPeak { parts.append("5-hour limit peaked at \(Int(p.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}
