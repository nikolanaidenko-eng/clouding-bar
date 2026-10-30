import SwiftUI

/// The Stats tab, the way Claude Code's /stats puts it: both limits now;
/// then, for the week, the month or everything, a few big numbers
/// (sessions, time, tokens, days in a row), every day as a square, and the
/// projects the time went to. The week hour by hour, the models and the
/// tools wait behind More.
struct StatsTab: View {
    @ObservedObject var model: AppModel
    @State private var stats: WeekStats?
    @State private var shown = false
    /// The heat map's square under the pointer: day and hour.
    @State private var hovered: (d: Int, h: Int)?
    /// The day square under the pointer ("2026-10-20").
    @State private var hoveredDay: String?
    /// "7", "30" or "all".
    @AppStorage("stats.range") private var range = "7"
    /// "both", "code" or "cowork".
    @AppStorage("stats.source") private var source = "both"

    /// The days of the source picked.
    private func days(_ s: WeekStats) -> [String: DayStats] {
        source == "code" ? s.history : source == "cowork" ? s.coworkHistory : DayStats.merged(s.history, s.coworkHistory)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rangeDays: Int? { Int(range) }
    private var rangeName: String { range == "7" ? "this week" : range == "30" ? "this month" : "so far" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            limits.tourAnchor("stats.limits")
            if let stats {
                let history = days(stats)
                let sum = StatsSummary.of(history, days: rangeDays)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source == "code" ? "Your Claude Code" : source == "cowork" ? "Your Cowork" : "Your Claude")
                            .font(.system(size: 17, weight: .semibold))
                        Text(subline(sum)).font(.system(size: 11)).foregroundColor(.sSecondary).lineLimit(1)
                    }
                    HStack {
                        SettingsSegments(options: [("both", "Both"), ("code", "Code"), ("cowork", "Cowork")],
                                         selected: source, tint: 0xFF375F) { r in
                            withAnimation(.cb(0.3)) { source = r }
                        }
                        Spacer(minLength: 8)
                        SettingsSegments(options: [("7", "Week"), ("30", "Month"), ("all", "All")],
                                         selected: range, tint: 0x30D158) { r in
                            withAnimation(.cb(0.3)) { range = r }
                        }
                    }
                    tiles(sum)
                    dayGrid(history)
                    dayLine(history)
                }
                .tourAnchor("stats.map")
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Where the time went").font(.system(size: 17, weight: .semibold))
                        Text("The projects Claude worked on \(rangeName). More has the week hour by hour, the models and the tools")
                            .font(.system(size: 11)).foregroundColor(.sSecondary)
                    }
                    projects(sum, stats)
                }
                .tourAnchor("stats.time")
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your sessions…").font(.system(size: 12)).foregroundColor(.sSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: load)
        // Cowork's numbers grow while this is open (counted as its cards are read).
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            guard var s = stats else { return }
            let cowork = DayStats.cowork(Cowork.kept())
            guard cowork != s.coworkHistory else { return }
            s.coworkHistory = cowork
            stats = s
        }
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
        // A Codex chat in front: the numbers are Codex's (its own files), so
        // they're called so, and Claude's charts stay out from under them.
        let agent = model.agentName
        let week = model.weekPercent.map { (percent: $0, note: model.weekReset.map { "Resets \($0)" } ?? "") }
            ?? (agent != nil ? nil : LimitHistory.latestWeek().flatMap { s in
                Date().timeIntervalSince(s.time) < 24 * 3600
                    ? (percent: s.percent, note: "From Claude Desktop, \(AppModel.ago(s.time))") : nil
            })
        return HStack(alignment: .top, spacing: 12) {
            card(agent.map { "\($0) 5-hour limit" } ?? "5-hour limit", model.sessionPercent,
                 model.resetLong.map { "Resets in \($0)" } ?? model.limitAge.map { "Last seen \($0)" } ?? "Not reported yet") {
                if agent == nil { sparkline(stats?.limitLine ?? []) }
            }
            card(agent.map { "\($0) weekly limit" } ?? "Weekly limit", week?.percent,
                 week?.note ?? "Shows once \(agent ?? "Claude Code") reports it") {
                if agent == nil { days(stats) }
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
        let inner = SettingsView.width - SettingsCloud.gutter - 18 - 24 // the tab's padding, the group's
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

    // MARK: Days

    /// "Mostly Opus 5.5 · peak hour 14:00 · busiest on Tuesdays"
    private func subline(_ s: StatsSummary) -> String {
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US")
        let parts: [String?] = [
            s.favoriteModel.map { "Mostly \($0)" },
            s.peakHour.map { "peak hour \($0):00" },
            s.busiestWeekday.map { "busiest on \(weekday.weekdaySymbols[$0 - 1])s" },
        ]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? "Nothing yet \(rangeName)" : text
    }

    private func tiles(_ s: StatsSummary) -> some View {
        HStack(spacing: 10) {
            tile("Sessions", "\(s.sessions)", s.activeDays > 0 ? "on \(s.activeDays) day\(s.activeDays == 1 ? "" : "s")" : nil)
            tile("Active", Self.duration(s.minutes), s.longest > 0 ? "longest \(Self.duration(s.longest))" : nil)
            tile("Tokens", AppModel.compact(s.tokens), "read and written")
            tile("Streak", "\(s.currentStreak) day\(s.currentStreak == 1 ? "" : "s")",
                 s.longestStreak > 0 ? "best \(s.longestStreak)" : nil)
        }
    }

    private func tile(_ title: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundColor(.sSecondary)
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(note ?? " ").font(.system(size: 10)).foregroundColor(.sMuted).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.sGroup))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.sLine, lineWidth: 0.5))
    }

    /// Every day of the last 26 weeks as a square, weeks across, Monday on
    /// top: the brighter, the longer Claude worked.
    private static let gridWeeks = 26, dayGap: CGFloat = 3
    private static var daySize: CGFloat {
        let inner = SettingsView.width - SettingsCloud.gutter - 18
        return min(18, floor((inner - labelWidth - dayGap - CGFloat(gridWeeks - 1) * dayGap) / CGFloat(gridWeeks)))
    }

    /// The grid's days: [week][weekday], nil after today.
    private static func gridDays(now: Date = Date()) -> [[Date?]] {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        let today = cal.startOfDay(for: now)
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let first = cal.date(byAdding: .weekOfYear, value: -(gridWeeks - 1), to: thisWeek)!
        return (0..<gridWeeks).map { w in
            (0..<7).map { d in
                let day = cal.date(byAdding: .day, value: w * 7 + d, to: first)!
                return day <= today ? day : nil
            }
        }
    }

    private func dayGrid(_ history: [String: DayStats]) -> some View {
        let weeks = Self.gridDays()
        let peak = max(1, weeks.joined().compactMap { $0 }.map { history[DayStats.key($0)]?.minutes ?? 0 }.max() ?? 1)
        let size = Self.daySize
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US")
        month.dateFormat = "MMM"
        let names = ["Mon", "", "Wed", "", "Fri", "", ""]
        let months = weeks.map { Calendar.current.component(.month, from: $0[0]!) }
        return VStack(alignment: .leading, spacing: Self.dayGap) {
            // Months over the weeks they start in.
            HStack(spacing: Self.dayGap) {
                Color.clear.frame(width: Self.labelWidth, height: 12)
                ForEach(weeks.indices, id: \.self) { w in
                    let start = weeks[w][0]!
                    // The first week's month only if a new one doesn't start right after.
                    let newMonth = w == 0 ? (months.count < 3 || (months[1] == months[0] && months[2] == months[0]))
                        : months[w - 1] != months[w]
                    Text(newMonth ? month.string(from: start) : "").font(.system(size: 9)).foregroundColor(.sSecondary)
                        .fixedSize().frame(width: size, height: 12, alignment: .leading)
                }
            }
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: Self.dayGap) {
                    Text(names[d]).font(.system(size: 9)).foregroundColor(.sSecondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    ForEach(weeks.indices, id: \.self) { w in
                        if let day = weeks[w][d] {
                            let key = DayStats.key(day)
                            let minutes = history[key]?.minutes ?? 0
                            let inRange = rangeDays.map { Calendar.current.dateComponents([.day], from: day, to: Date()).day! < $0 } ?? true
                            let on = hoveredDay == key
                            RoundedRectangle(cornerRadius: 3)
                                .fill(minutes == 0 ? Color.sMeterTrack
                                      : Color.sChart.opacity(0.25 + 0.75 * min(1, Double(minutes) / Double(peak))))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.sText.opacity(on ? 0.85 : 0), lineWidth: 1.5))
                                .opacity(inRange ? 1 : 0.35)
                                .frame(width: size, height: size)
                                .scaleEffect(shown ? (on ? 1.2 : 1) : 0.4)
                                .opacity(shown ? 1 : 0)
                                .zIndex(on ? 1 : 0)
                                .animation(.cb(0.26).delay(Double(w * 10 + d * 6) / 1000), value: shown)
                                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
                                .onHover { inside in
                                    if inside { hoveredDay = key } else if on { hoveredDay = nil }
                                }
                        } else {
                            Color.clear.frame(width: size, height: size)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Days of Claude Code over the last half year")
    }

    /// Under the grid: the day under the pointer; else today.
    private func dayLine(_ history: [String: DayStats]) -> some View {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEEE d MMM"
        let key = hoveredDay ?? DayStats.key(Date())
        let day = history[key]
        let date = DayStats.keyFormat.date(from: key) ?? Date()
        let projects = (day?.projects ?? [:]).sorted { $0.value > $1.value }.prefix(3).map(\.key)
        let n = Set(day?.sessions ?? []).count
        let cowork = Set((day?.sessions ?? []).filter { $0.hasPrefix("cowork-") }).count
        let parts: [String?] = [
            hoveredDay == nil ? "Today" : fmt.string(from: date),
            (day?.minutes ?? 0) > 0 ? "worked \(Self.duration(day!.minutes))" : "no Claude Code",
            (day?.tokens ?? 0) > 0 ? "\(AppModel.compact(day!.tokens)) tokens" : nil,
            n > 0 ? "\(n) session\(n == 1 ? "" : "s")" + (cowork > 0 && cowork < n ? " (\(cowork) Cowork)" : "") : nil,
            projects.isEmpty ? nil : projects.joined(separator: ", "),
        ]
        return (Text(parts.compactMap { $0 }.joined(separator: " · ")).foregroundColor(hoveredDay == nil ? .sSecondary : .sText)
            + Text(hoveredDay == nil ? "\nPoint at a day to see it" : "").foregroundColor(.sMuted))
            .font(.system(size: 11).monospacedDigit()).lineSpacing(3).lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            .animation(nil, value: hoveredDay)
    }

    // MARK: Projects

    private func projects(_ sum: StatsSummary, _ s: WeekStats) -> some View {
        let top = Array(sum.projects.prefix(5))
        let peak = max(1, top.first?.minutes ?? 1)
        let rest = sum.projects.dropFirst(5)
        let shades = [Color.sChart, Color(hex: 0xBF5AF2), Color(hex: 0x30B0C7), Color(hex: 0xFF9F0A), Color(hex: 0x30D158)]
        return SettingsGroup {
            if top.isEmpty {
                row("") { Text("No projects \(rangeName) yet").foregroundColor(.sSecondary) }
            }
            ForEach(Array(top.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 10) {
                    Circle().fill(shades[i]).frame(width: 7, height: 7)
                    Text(p.name).lineLimit(1).truncationMode(.middle).frame(width: 130, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(shades[i].opacity(0.85))
                            .frame(width: max(4, geo.size.width * CGFloat(p.minutes) / CGFloat(peak) * (shown ? 1 : 0.05)))
                            .frame(maxHeight: .infinity, alignment: .center)
                            .animation(.cb(0.5).delay(Double(i) * 0.05), value: shown)
                    }
                    .frame(height: 6)
                    Text(Self.duration(p.minutes)).foregroundColor(.sSecondary).frame(width: 82, alignment: .trailing)
                }
                .font(.system(size: 12).monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(Rectangle().fill(Color.sLine).frame(height: 0.5), alignment: .bottom)
            }
            if !rest.isEmpty {
                row("") {
                    Text("+ \(rest.count) more · \(Self.duration(rest.reduce(0) { $0 + $1.minutes }))").foregroundColor(.sSecondary)
                }
            }
            MoreRows("stats", count: 3) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The week, hour by hour").font(.system(size: 12, weight: .semibold))
                        Text(s.headline + " · " + subtitle(s).prefix(1).lowercased() + subtitle(s).dropFirst())
                            .font(.system(size: 11)).foregroundColor(.sSecondary)
                    }
                    heatMap(s)
                    hoverLine(s)
                }
                .padding(12)
                .overlay(Rectangle().fill(Color.sLine).frame(height: 0.5), alignment: .bottom)
                let models = sum.models.filter { $0.share >= 0.005 }
                if !models.isEmpty {
                    row("Models") {
                        shares(models.count > 4 ? Array(models.prefix(3)) + [(name: "other", share: models.dropFirst(3).reduce(0) { $0 + $1.share })] : models)
                    }
                }
                row("Tools") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.tools.isEmpty ? "—" : s.tools.map { "\($0.name) \($0.count)" }.joined(separator: " · "))
                        Text("this week · \(s.subagents) subagent\(s.subagents == 1 ? "" : "s") started").foregroundColor(.sSecondary)
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
