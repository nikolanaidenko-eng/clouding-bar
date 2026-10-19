import SwiftUI

/// The settings window (600×560), one tab per place things show up:
/// General (the app, context, voice), Widget (the pill and the panel),
/// Touch Bar, Buttons (and templates), Cowork, Stats. Cloud in the corner
/// keeps you company: it watches the pointer, cheers at every change, and
/// looks away while you type a key.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: String
    @StateObject private var mood = CloudMood()

    static let tabs = [("general", "General"), ("widget", "Widget"), ("touchbar", "Touch Bar"),
                       ("buttons", "Buttons"), ("cowork", "Cowork"), ("stats", "Stats")]
    static let width: CGFloat = 600

    init(model: AppModel, tab: String = "general") {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LiveMascot(size: 32, mood: mood)
                    .frame(width: 32, height: 32)
                    .overlay(Color.clear.contentShape(Rectangle()).onTapGesture { mood.pokes += 1 })
                    .help("Cloud")
                Text("Clouding Bar").font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 0) {
                    ForEach(Self.tabs, id: \.0) { id, label in
                        Button(label) {
                            guard tab != id else { return }
                            withAnimation(.easeOut(duration: 0.18)) { tab = id }
                            mood.hops += 1
                        }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(tab == id ? Color(hex: 0x636366) : .clear))
                            .accessibilityAddTraits(tab == id ? .isSelected : [])
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
            }
            // Room on the left for the window's close button.
            .padding(.leading, 40).padding(.trailing, 18).padding(.vertical, 11)
            .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5), alignment: .bottom)

            ScrollView {
                Group {
                    switch tab {
                    case "general": GeneralTab(model: model)
                    case "widget": WidgetTab(model: model)
                    case "touchbar": TouchBarTab(model: model)
                    case "buttons": ButtonsTab(model: model)
                    case "cowork": CoworkTab(model: model, mood: mood)
                    default: StatsTab()
                    }
                }
                .padding(18)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .foregroundColor(.cbText)
        .frame(width: Self.width, height: 560)
        .background(Color(hex: 0x232325))
        .environment(\.colorScheme, .dark)
        // Every change gets a cheer.
        .onChange(of: model.config) { _ in mood.pokes += 1 }
    }
}

/// What Cloud in the settings window is up to.
final class CloudMood: ObservableObject {
    /// A click on it or a change: a happy jump (five quick ones: a spin).
    @Published var pokes = 0
    /// Another tab: a little hop.
    @Published var hops = 0
    /// The key field is open: eyes shut, turned away.
    @Published var shy = false
}

/// Cloud that watches the pointer, dozes off and wakes by itself.
struct LiveMascot: NSViewRepresentable {
    let size: CGFloat
    @ObservedObject var mood: CloudMood

    final class Coordinator { var pokes = 0; var hops = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MascotView {
        context.coordinator.pokes = mood.pokes
        context.coordinator.hops = mood.hops
        let view = MascotView(size: size)
        view.lively = true
        return view
    }

    func updateNSView(_ view: MascotView, context: Context) {
        view.shy = mood.shy
        let c = context.coordinator
        if mood.pokes != c.pokes { c.pokes = mood.pokes; view.poke() }
        if mood.hops != c.hops { c.hops = mood.hops; view.hop() }
    }
}

// MARK: - Pieces

struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }
}

/// A titled group: a small heading over the rounded box, and a note under it.
struct SettingsSection<Content: View>: View {
    let title: String
    var note = ""
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.cbSecondary)
                .padding(.leading, 12)
            SettingsGroup { content }
            if !note.isEmpty {
                Text(note).font(.system(size: 11)).foregroundColor(.cbMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var hint: String = ""
    var divider = true
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if !hint.isEmpty {
                    Text(hint).font(.system(size: 11)).foregroundColor(.cbSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 46)
        .overlay(divider ? Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) : nil, alignment: .bottom)
    }
}

/// The 40×24 switch from the mockup.
struct CBSwitch: View {
    let title: String
    @Binding var on: Bool
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.16)) { on.toggle() } } label: {
            Capsule().fill(on ? Color(hex: 0x0A84FF) : Color(hex: 0x48484A))
                .frame(width: 40, height: 24)
                .overlay(Circle().fill(.white).frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .padding(2), alignment: on ? .trailing : .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
    }
}

struct CBCheckbox: View {
    let title: String
    var hint = ""
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5).fill(on ? Color(hex: 0x0A84FF) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.clear : Color(hex: 0x636366), lineWidth: 1))
                    .overlay(Text(on ? "✓" : "").font(.system(size: 12)).foregroundColor(.white))
                    .frame(width: 18, height: 18)
                Text(title).font(.system(size: 12)) + Text(hint.isEmpty ? "" : " \(hint)").font(.system(size: 12)).foregroundColor(.cbSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
    }
}

struct Chip: View {
    let label: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(on ? Color(hex: 0x0A84FF) : .clear))
            .overlay(Capsule().strokeBorder(on ? Color.clear : Color(hex: 0x636366), lineWidth: 1))
            .fixedSize()
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Chips that turn ids in one of the settings' lists on and off.
struct ChipSet: View {
    @ObservedObject var model: AppModel
    /// The config key holding the list.
    let key: String
    let options: [(id: String, label: String)]
    /// Also kept in step: the same ids in another list (cost is both a
    /// number on the pill and a metric in the panel).
    var mirror: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.id) { option in
                Chip(label: option.label, on: list(key).contains(option.id)) { toggle(option.id) }
            }
        }
    }

    private func list(_ key: String) -> [String] {
        switch key {
        case "pillShows": return model.config.pillShows
        case "metrics": return model.config.metrics
        case "touchBarShows": return model.config.touchBarShows
        default: return []
        }
    }

    private func toggle(_ id: String) {
        let on = !list(key).contains(id)
        for k in [key] + (mirror.map { [$0] } ?? []) {
            var l = list(k).filter { $0 != id }
            if on { l.append(id) }
            if l != list(k) { model.setConfig(k, l) }
        }
    }
}

/// A setting's switch bound to a Bool key.
func settingBinding(_ model: AppModel, _ key: String, _ get: @escaping (Config) -> Bool) -> Binding<Bool> {
    Binding(get: { get(model.config) }, set: { model.setConfig(key, $0) })
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: AppModel

    private func binding(_ key: String, _ get: @escaping (Config) -> Bool) -> Binding<Bool> {
        settingBinding(model, key, get)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "App") {
                SettingsRow(title: "Open at login") {
                    CBSwitch(title: "Open at login", on: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                }
                SettingsRow(title: "Do not disturb", hint: "Requests wait quietly: nothing pops open or pulses") {
                    CBSwitch(title: "Do not disturb", on: binding("doNotDisturb") { $0.doNotDisturb })
                }
                SettingsRow(title: "Tour", hint: "How everything works, in seven short pages", divider: false) {
                    Button("Show") { model.showTour() }
                }
            }

            SettingsSection(title: "Claude Code") {
                SettingsRow(title: "Hooks",
                            hint: model.claudeConnected ? "Connected: Claude Code tells Clouding Bar what it's doing"
                                : "Not connected yet: Clouding Bar can't see Claude Code. Your settings.json is backed up first.",
                            divider: model.hasVSCode || model.setupMessage != nil) {
                    if model.claudeConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.cbSecondary)
                    } else {
                        Button("Connect") { model.connectClaude() }
                    }
                }
                if model.hasVSCode {
                    SettingsRow(title: "5-hour limit in VS Code",
                                hint: "VS Code runs Claude through Clouding Bar's wrapper, which passes the limit on. New chats only.",
                                divider: model.setupMessage != nil) {
                        if model.vscodeWrapped {
                            Label("On", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.cbSecondary)
                        } else {
                            Button("Set Up") { model.wrapVSCode() }
                        }
                    }
                }
                if let message = model.setupMessage {
                    Text(message).font(.system(size: 11)).foregroundColor(.cbSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }

            SettingsSection(title: "Context") {
                SettingsRow(title: "Warn when it fills up", hint: "The bar turns red and offers /compact") {
                    HStack(spacing: 10) {
                        Picker("", selection: Binding(get: { Int(model.config.contextWarnPercent) },
                                                      set: { model.setConfig("contextWarnPercent", $0) })) {
                            ForEach([60, 70, 80, 90], id: \.self) { Text("at \($0)%").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        .disabled(!model.config.contextWarning)
                        .accessibilityLabel("Warn at")
                        CBSwitch(title: "Context warning", on: binding("contextWarning") { $0.contextWarning })
                    }
                }
                SettingsRow(title: "Compact by itself",
                            hint: "At the warning it types /compact, when Claude is idle and its window is in front",
                            divider: false) {
                    CBSwitch(title: "Compact by itself", on: binding("autoCompact") { $0.autoCompact })
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Voice").font(.system(size: 11, weight: .semibold)).foregroundColor(.cbSecondary)
                    .padding(.leading, 12)
                VoiceGroup(model: model)
            }
        }
    }
}

/// Dictation language, and whether it works offline on this Mac.
struct VoiceGroup: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Language", hint: "Hold the right ⌥ key alone, or the widget's mic. Text goes in without Enter.",
                        divider: !model.voiceOffline) {
                Picker("", selection: Binding(get: { model.config.voiceLanguage },
                                              set: { model.setConfig("voiceLanguage", $0) })) {
                    ForEach(VoiceInput.languages, id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id).map { "\($0) (\(id))" } ?? id).tag(id)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .accessibilityLabel("Voice language")
            }
            if !model.voiceOffline {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundColor(.cbWarning)
                        Text("This language isn't available offline on this Mac. To use it, your voice is sent to Apple's servers for recognition.")
                            .font(.system(size: 11)).foregroundColor(Color(hex: 0xD1D1D6)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CBCheckbox(title: "Allow sending audio to Apple", on: Binding(
                        get: { model.config.voiceAllowServer }, set: { model.setConfig("voiceAllowServer", $0) }))
                        .padding(.horizontal, -12)
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Widget

struct WidgetTab: View {
    @ObservedObject var model: AppModel

    private func binding(_ key: String, _ get: @escaping (Config) -> Bool) -> Binding<Bool> {
        settingBinding(model, key, get)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Floating widget") {
                SettingsRow(title: "Show the widget", hint: "A pill over your windows; the full panel opens from it",
                            divider: model.config.widget) {
                    CBSwitch(title: "Show the widget", on: binding("widget") { $0.widget })
                }
                if model.config.widget {
                    SettingsRow(title: "Keep the pill visible", hint: "Off: a thin line until you hover it") {
                        CBSwitch(title: "Keep the pill visible", on: binding("pillAlwaysVisible") { $0.pillAlwaysVisible })
                    }
                    SettingsRow(title: "Open on hover", hint: "The full panel after 2 s on the pill; off: click it") {
                        CBSwitch(title: "Open on hover", on: binding("hoverOpens") { $0.hoverOpens })
                    }
                    SettingsRow(title: "In the notch",
                                hint: (model.hasNotch ? "Around the camera" : "This Mac has no notch, so one is drawn")
                                    + ": the numbers sit in it, the panel opens from it. Drag it out to put it anywhere, drag it back to dock.") {
                        CBSwitch(title: "In the notch", on: Binding(
                            get: { model.config.widgetAtNotch && model.config.widgetPosition == nil },
                            set: { on in
                                model.setConfig("widgetAtNotch", on)
                                if on { model.resetWidgetPosition() }
                            }))
                    }
                    SettingsRow(title: "Position",
                                hint: model.config.widgetPosition != nil ? "Where you dragged it"
                                    : model.config.widgetAtNotch ? "In the notch" : "Top center, under the menu bar",
                                divider: false) {
                        Button("Reset") { model.resetWidgetPosition() }
                            .disabled(model.config.widgetPosition == nil)
                    }
                }
            }

            SettingsSection(title: "What it shows",
                            note: "Each chip turns one thing on or off in the pill, the notch and the panel. The pill shows what fits its size: pull its outline to resize it, drag one item onto another to swap them. Chat: write to Claude from the widget, sent once it's free and its chat is in front; files dropped on the widget go with it.") {
                SettingsRow(title: "Numbers") {
                    ToggleChips(items: [hideChip("Session", "session"), listChip("Context", "pillShows", "context"),
                                        listChip("Reset time", "pillShows", "reset"),
                                        listChip("Cost", "pillShows", "cost", mirror: "metrics")])
                }
                SettingsRow(title: "Details") {
                    ToggleChips(items: [listChip("Model", "metrics", "model"), listChip("Lines", "metrics", "lines"),
                                        listChip("Branch", "metrics", "git"), listChip("Subagents", "metrics", "agents")])
                }
                SettingsRow(title: "Controls", divider: false) {
                    ToggleChips(items: [hideChip("Buttons", "buttons"), boolChip("Chat", "taskQueue") { $0.taskQueue },
                                        boolChip("Templates", "templatesEnabled") { $0.templatesEnabled },
                                        boolChip("Screenshot", "screenshot") { $0.screenshot }, hideChip("Mic", "mic")])
                }
            }

            SettingsSection(title: "Panel") {
                SettingsRow(title: "Sessions list", hint: "Jump between your Claude sessions from the panel", divider: false) {
                    CBSwitch(title: "Sessions list", on: binding("sessionsList") { $0.sessionsList })
                }
            }
        }
    }

    // MARK: Chips

    private func list(_ key: String) -> [String] {
        switch key {
        case "pillShows": return model.config.pillShows
        case "metrics": return model.config.metrics
        default: return model.config.widgetHides
        }
    }

    /// On while `id` is in the list `key` (and `mirror`, kept in step).
    private func listChip(_ label: String, _ key: String, _ id: String, mirror: String? = nil) -> ToggleChips.Item {
        let on = list(key).contains(id)
        return (label, on, {
            for k in [key] + (mirror.map { [$0] } ?? []) {
                var l = list(k).filter { $0 != id }
                if !on { l.append(id) }
                if l != list(k) { model.setConfig(k, l) }
            }
        })
    }

    /// On unless `id` is in widgetHides (things the widget used to always show).
    private func hideChip(_ label: String, _ id: String) -> ToggleChips.Item {
        let on = !model.config.widgetHides.contains(id)
        return (label, on, {
            var l = model.config.widgetHides.filter { $0 != id }
            if on { l.append(id) }
            model.setConfig("widgetHides", l)
        })
    }

    private func boolChip(_ label: String, _ key: String, _ get: @escaping (Config) -> Bool) -> ToggleChips.Item {
        let on = get(model.config)
        return (label, on, { model.setConfig(key, !on) })
    }
}

/// Chips that each turn one thing on or off.
struct ToggleChips: View {
    typealias Item = (label: String, on: Bool, toggle: () -> Void)
    let items: [Item]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                Chip(label: items[i].label, on: items[i].on, action: items[i].toggle)
            }
        }
    }
}

// MARK: - Touch Bar

struct TouchBarTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TouchBarPreview(model: model)
                .opacity(model.config.touchBar == "off" ? 0.4 : 1)
            SettingsGroup {
                SettingsRow(title: "Show on Touch Bar",
                            hint: model.touchBarPresent ? "Detected on this Mac" : "No Touch Bar found on this Mac") {
                    CBSwitch(title: "Show on Touch Bar", on: Binding(
                        get: { model.config.touchBar != "off" },
                        set: { model.setConfig("touchBar", $0 ? (model.touchBarPresent ? "auto" : "on") : "off") }))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the bar").font(.system(size: 13))
                    ChipSet(model: model, key: "touchBarShows",
                            options: [("session", "Session"), ("reset", "Reset time"), ("context", "Context")])
                    ChipSet(model: model, key: "touchBarShows",
                            options: [("model", "Model"), ("agents", "Subagents"), ("buttons", "Buttons"),
                                      ("shot", "Screenshot"), ("mic", "Mic")])
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Claude's questions and permission requests always show. Tap the model on the bar to switch it, the subagents to see who's working; the buttons are set up in Buttons.")
                .font(.system(size: 11)).foregroundColor(.cbMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }
}

// MARK: - Buttons

struct ButtonsTab: View {
    @ObservedObject var model: AppModel
    @State private var profile = ""   // "" = the main list
    @State private var selected: Int?
    @State private var editing = false
    @State private var draftName = ""
    @State private var draftValue = ""
    @State private var draftType: ButtonSpec.Kind = .phrase
    /// The type follows the value until you pick one yourself.
    @State private var typePicked = false
    @State private var draftHotkey: String?
    @State private var newTemplate = ""

    private var list: [ButtonSpec] {
        profile.isEmpty ? model.config.effectiveButtons : (model.config.profiles[profile] ?? model.config.effectiveButtons)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Touch Bar preview · meters shrink as you add buttons").font(.system(size: 11)).foregroundColor(.cbSecondary)
                TouchBarPreview(model: model,
                                labels: list.map(\.label) + (editing && selected == nil ? [draftName.isEmpty ? "New" : draftName] : []),
                                highlightLast: editing && selected == nil)
            }
            SettingsGroup {
                ForEach(Array(list.enumerated()), id: \.offset) { i, b in
                    Button { startEdit(i) } label: {
                        HStack(spacing: 12) {
                            Text(b.label).font(.system(size: 13)).lineLimit(1).frame(width: 90, alignment: .leading)
                            Text(b.value).font(.system(size: 12)).foregroundColor(.cbSecondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(b.type.rawValue + (b.hotkey.map { " · " + HotKeys.display($0) } ?? ""))
                                .font(.system(size: 12)).foregroundColor(.cbSecondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(selected == i ? Color(hex: 0x0A84FF).opacity(0.25) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5), alignment: .bottom)
                }
                if editing { editor }
                HStack(spacing: 2) {
                    Button("+") { startAdd() }.buttonStyle(.plain).font(.system(size: 17))
                        .frame(width: 36, height: 30).accessibilityLabel("Add button")
                    Button("−") { remove() }.buttonStyle(.plain).font(.system(size: 17)).foregroundColor(.cbSecondary)
                        .frame(width: 36, height: 30).accessibilityLabel("Remove button")
                    Spacer()
                    Text("Profile").font(.system(size: 11)).foregroundColor(.cbSecondary)
                    Picker("", selection: $profile) {
                        Text("Default").tag("")
                        ForEach(profileChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel("Profile")
                }
                .padding(.horizontal, 4).padding(.vertical, 2)
            }
            templatesSection
            if !profile.isEmpty {
                Text(model.config.profiles[profile] == nil
                     ? "\(profile) uses the default buttons. Change one here to give it its own set."
                     : "Buttons for sessions in \(profile).")
                    .font(.system(size: 11)).foregroundColor(.cbSecondary)
            }
        }
        .onChange(of: profile) { _ in editing = false; selected = nil }
    }

    /// Template phrases: typed into Claude without Enter, with {project},
    /// {branch}, {clipboard} and {date} filled in.
    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Templates · {project} {branch} {clipboard} {date}")
                    .font(.system(size: 11)).foregroundColor(.cbSecondary)
                Spacer()
                Text(model.config.templatesEnabled ? "In the widget and the menu" : "Off")
                    .font(.system(size: 11)).foregroundColor(.cbSecondary)
                CBSwitch(title: "Templates", on: settingBinding(model, "templatesEnabled") { $0.templatesEnabled })
                    .scaleEffect(0.8)
            }
            .padding(.leading, 12)
            SettingsGroup {
                ForEach(Array(model.config.templates.enumerated()), id: \.offset) { i, t in
                    HStack {
                        Text(t).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("−") {
                            var list = model.config.templates
                            list.remove(at: i)
                            model.setConfig("templates", list)
                        }
                        .buttonStyle(.plain).foregroundColor(.cbSecondary)
                        .accessibilityLabel("Remove template")
                    }
                    .padding(.horizontal, 12).frame(minHeight: 34)
                    .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5), alignment: .bottom)
                }
                HStack(spacing: 8) {
                    TextField("New template", text: $newTemplate)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
                        .onSubmit(addTemplate)
                    Button("Add", action: addTemplate).buttonStyle(.plain).font(.system(size: 12))
                        .disabled(newTemplate.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private func addTemplate() {
        let t = newTemplate.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.setConfig("templates", model.config.templates + [t])
        newTemplate = ""
    }

    private var editor: some View {
        VStack(spacing: 8) {
        HStack(spacing: 8) {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 8).frame(width: 110, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            Picker("", selection: Binding(get: { draftType }, set: { draftType = $0; typePicked = true })) {
                ForEach(ButtonSpec.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 110)
            .accessibilityLabel("Type")
            ShortcutField(combo: $draftHotkey).frame(width: 120, height: 30)
            Spacer(minLength: 0)
        }
        HStack(spacing: 8) {
            TextField(placeholder, text: $draftValue)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 8).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .onChange(of: draftValue) { v in if !typePicked { draftType = ButtonSpec.guessType(v) } }
            Button(selected == nil ? "Add" : "Save") { commit() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.cbAction))
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty
                          || (draftValue.isEmpty && draftType != .screenshot))
        }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5), alignment: .bottom)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private var placeholder: String {
        switch draftType {
        case .phrase: return "Text to send to Claude"
        case .command: return "/command"
        case .key: return "esc, cmd+k, shift+tab…"
        case .link: return "vscode://… or https://…"
        case .screenshot: return "Nothing needed: it picks an area of the screen"
        }
    }

    private var profileChoices: [String] {
        Array(Set(model.knownProjects).union(model.config.profiles.keys)).sorted()
    }

    private func startAdd() {
        selected = nil
        draftName = ""
        draftValue = ""
        draftType = .phrase
        typePicked = false
        draftHotkey = nil
        withAnimation(.easeOut(duration: 0.18)) { editing = true }
    }

    private func startEdit(_ i: Int) {
        selected = i
        draftName = list[i].label
        draftValue = list[i].value
        draftType = list[i].type
        draftHotkey = list[i].hotkey
        typePicked = true
        withAnimation(.easeOut(duration: 0.18)) { editing = true }
    }

    private func commit() {
        let spec = ButtonSpec(label: draftName.trimmingCharacters(in: .whitespaces), type: draftType,
                              value: draftValue, hotkey: draftHotkey)
        var buttons = list
        if let i = selected, buttons.indices.contains(i) { buttons[i] = spec } else { buttons.append(spec) }
        save(buttons)
        editing = false
        selected = nil
    }

    private func remove() {
        var buttons = list
        guard !buttons.isEmpty else { return }
        if let i = selected, buttons.indices.contains(i) { buttons.remove(at: i) } else { buttons.removeLast() }
        save(buttons)
        editing = false
        selected = nil
    }

    private func save(_ buttons: [ButtonSpec]) {
        if profile.isEmpty {
            model.setConfig("buttons", buttons.map(\.dictionary))
        } else {
            var profiles = model.config.profiles
            profiles[profile] = buttons
            model.setConfig("profiles", profiles.mapValues { $0.map(\.dictionary) })
        }
    }
}

/// The Touch Bar as it's set up, with this Mac's numbers: the character,
/// then whatever Settings → Touch Bar turns on, in the bar's order. Session
/// and Context share what the rest leaves (3 : 2) and drop their words as
/// room runs out, the same rule as the real bar.
struct TouchBarPreview: View {
    @ObservedObject var model: AppModel
    /// The buttons to show; the Buttons tab passes the list being edited.
    var labels: [String]? = nil
    var highlightLast = false

    private static let pad: CGFloat = 5, gap: CGFloat = 5, character: CGFloat = 36, icon: CGFloat = 30

    var body: some View {
        GeometryReader { geo in bar(width: geo.size.width) }
            .frame(height: 38)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Touch Bar preview: " + Set(model.config.touchBarShows).sorted().joined(separator: ", "))
    }

    private func bar(width: CGFloat) -> some View {
        let shows = Set(model.config.touchBarShows)
        let buttons = shows.contains("buttons")
            ? labels ?? (model.buttons.isEmpty ? model.config.effectiveButtons : model.buttons).map(\.label) : []
        let modelText = shows.contains("model")
            ? ModelChoice.label(model: model.modelName ?? "Opus 5.5 1M", effort: model.modelName == nil ? "xhigh" : model.effort)
            : nil
        let session = shows.contains("session"), context = shows.contains("context")
        let buttonWidths = buttons.map { min(84, Self.text($0, 11) + 16) }
        let modelWidth = modelText.map { min(130, Self.text($0, 10) + 16) } ?? 0
        let agentsText = shows.contains("agents")
            ? (model.agents == 0 ? "No agents" : "\(model.agents) agent\(model.agents == 1 ? "" : "s")") : nil
        let agentsWidth = agentsText.map { Self.text($0, 10) + 16 } ?? 0
        let icons = [shows.contains("shot") ? "camera.viewfinder" : nil, shows.contains("mic") ? "mic" : nil].compactMap { $0 }
        let items = 1 + buttons.count + (modelText == nil ? 0 : 1) + (agentsText == nil ? 0 : 1) + icons.count
            + (session || context ? 1 : 0)
        let used = Self.pad * 2 + Self.character + buttonWidths.reduce(0, +) + modelWidth + agentsWidth
            + CGFloat(icons.count) * Self.icon + Self.gap * CGFloat(items - 1)
        let room = max(0, width - used)
        return HStack(spacing: Self.gap) {
            key { MascotIcon(activity: model.activity, size: 22).frame(width: 22, height: 22) }
                .frame(width: Self.character)
            if session || context {
                meters(room: room, session: session, context: context).frame(width: room)
            }
            if let modelText {
                key { Text(modelText).font(.system(size: 10)).lineLimit(1) }.frame(width: modelWidth)
            }
            if let agentsText {
                key { Text(agentsText).font(.system(size: 10)).lineLimit(1) }.frame(width: agentsWidth)
            }
            ForEach(Array(buttons.enumerated()), id: \.offset) { i, label in
                key(fill: highlightLast && i == buttons.count - 1 ? Color(hex: 0x0A3D78) : Color(hex: 0x2C2C2E)) {
                    Text(label).font(.system(size: 11)).lineLimit(1).truncationMode(.tail).padding(.horizontal, 4)
                }
                .frame(width: buttonWidths[i])
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            ForEach(icons, id: \.self) { name in
                key { Image(systemName: name).font(.system(size: 11)) }.frame(width: Self.icon)
            }
            if !(session || context) { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Self.pad)
        .frame(width: width, height: 38)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.25), value: shows)
        .animation(.easeOut(duration: 0.25), value: buttons)
    }

    /// One key of the bar: a dark rounded button.
    private func key<Label: View>(fill: Color = Color(hex: 0x2C2C2E), @ViewBuilder _ label: () -> Label) -> some View {
        label()
            .foregroundColor(.cbText)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
    }

    private func meters(room: CGFloat, session: Bool, context: Bool) -> some View {
        let both = session && context
        let inner = max(0, room - 8 - (both ? 10 : 0))
        let sessionRoom = both ? inner * 3 / 5 : inner
        let reset = model.config.touchBarShows.contains("reset") ? (model.resetShort ?? "1:23") : nil
        return HStack(spacing: 10) {
            if session {
                meter(sessionRoom >= 140 ? "Session" : sessionRoom >= 80 ? "5h" : "",
                      value: "\(Int(model.sessionPercent ?? 42))%" + (reset.map { sessionRoom >= 80 ? " · \($0)" : "" } ?? ""),
                      percent: (model.sessionPercent ?? 42) / 100)
                    .frame(width: sessionRoom)
            }
            if context {
                let w = both ? inner * 2 / 5 : inner
                meter(w >= 100 ? "Context" : w >= 60 ? "Ctx" : "", value: "\(Int(model.contextPercent ?? 31))%",
                      percent: (model.contextPercent ?? 31) / 100)
                    .frame(width: w)
            }
        }
        .padding(.horizontal, 4)
    }

    private func meter(_ label: String, value: String, percent: Double) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).foregroundColor(.cbSecondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(value).lineLimit(1)
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(.cbText)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: 0x2C2C2E))
                    Capsule().fill(Color.cbFill).frame(width: geo.size.width * CGFloat(min(1, max(0, percent))))
                }
            }
            .frame(height: 3)
        }
    }

    private static func text(_ s: String, _ size: CGFloat) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
    }
}

/// Click, then press a shortcut (with ⌃, ⌥, ⇧ or ⌘). Esc cancels,
/// Delete clears it.
struct ShortcutField: NSViewRepresentable {
    @Binding var combo: String?

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onChange = { combo = $0 }
        return v
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onChange = { combo = $0 }
        view.combo = combo
    }

    final class RecorderView: NSView {
        var combo: String? { didSet { update() } }
        var onChange: ((String?) -> Void)?
        private let label = NSTextField(labelWithString: "")
        private var recording = false { didSet { update() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 7
            layer?.borderWidth = 0.5
            label.font = .systemFont(ofSize: 12)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ])
            setAccessibilityRole(.button)
            update()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        private var monitor: Any?

        /// A click starts recording. Keys are caught by a local monitor, so
        /// nothing else in the window (SwiftUI, the Edit menu) gets them first.
        override func mouseDown(with event: NSEvent) {
            recording ? stop() : start()
        }

        private func start() {
            recording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
                guard let self else { return e }
                if e.type == .leftMouseDown {
                    // A click anywhere else ends recording; on us, mouseDown does.
                    if e.window !== self.window || !self.bounds.contains(self.convert(e.locationInWindow, from: nil)) {
                        self.stop()
                    }
                    return e
                }
                self.capture(e)
                return nil
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            recording = false
        }

        private func capture(_ event: NSEvent) {
            switch event.keyCode {
            case 53: // esc: keep what was there
                stop()
            case 51, 117: // delete: no shortcut
                combo = nil
                onChange?(nil)
                stop()
            default:
                guard let c = HotKeys.combo(from: event) else { NSSound.beep(); return } // needs ⌃, ⌥, ⇧ or ⌘
                combo = c
                onChange?(c)
                stop()
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stop() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func update() {
            label.stringValue = recording ? "Press keys…" : combo.map(HotKeys.display) ?? "Shortcut"
            label.textColor = recording || combo != nil ? NSColor(hex: 0xF5F5F7) : NSColor(hex: 0xA1A1A6)
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            layer?.borderColor = (recording ? NSColor(hex: 0x0A84FF) : NSColor.white.withAlphaComponent(0.18)).cgColor
            setAccessibilityLabel("Shortcut: " + (combo.map(HotKeys.display) ?? "none"))
        }
    }
}

// MARK: - Cowork

struct CoworkTab: View {
    @ObservedObject var model: AppModel
    var mood: CloudMood? = nil
    @State private var keyOpen = false
    @State private var key = ""

    private let notes = [
        "off": "Cowork chats are not tracked.",
        "thresholds": "Saves at 50, 80, 90% and when a task is done. Almost free.",
        "every": "After every reply: about +5–15% usage, +1–3 s per reply.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Cowork status").font(.system(size: 13))
                        Text("Claude saves context to a connected folder").font(.system(size: 11)).foregroundColor(.cbSecondary)
                    }
                    Spacer()
                    HStack(spacing: 0) {
                        ForEach([("off", "Off"), ("thresholds", "Thresholds"), ("every", "Every reply")], id: \.0) { id, label in
                            Button(label) { model.setConfig("coworkMode", id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(model.config.coworkMode == id ? Color(hex: 0x636366) : .clear))
                                .accessibilityAddTraits(model.config.coworkMode == id ? .isSelected : [])
                        }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.3)))
                }
                Text(notes[model.config.coworkMode] ?? "").font(.system(size: 11)).foregroundColor(.cbSecondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))

            if model.config.coworkMode != "off" {
                SettingsGroup {
                    SettingsRow(title: "Plugin",
                                hint: "Upload it in Claude Desktop → Settings → Plugins. Make it again after changing the mode.") {
                        Button("Make plugin") { model.makeCoworkPlugin() }
                    }
                    SettingsRow(title: "Folders",
                                hint: (model.coworkFolders.isEmpty
                                    ? "Connect a folder to a Cowork task; it's found by itself."
                                    : "Watching " + model.coworkFolders.joined(separator: ", ") + ".")
                                    + " Only tasks with a connected folder can report their context.") {
                        Button("Add…") { model.chooseCoworkFolder() }
                    }
                    SettingsRow(title: "Last status", hint: model.coworkLast ?? "None yet", divider: model.coworkMessage != nil) {
                        EmptyView()
                    }
                    if let message = model.coworkMessage {
                        Text(message).font(.system(size: 11)).foregroundColor(.cbSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }

            SettingsGroup {
                SettingsRow(title: "Live limit via claude.ai",
                            hint: "Desktop and Cowork chats · \(model.liveLimitState)", divider: keyOpen) {
                    if model.hasLiveKey {
                        Button("Remove key") { model.removeLiveKey(); keyOpen = false }
                    } else {
                        Button(keyOpen ? "Hide" : "Set up…") { withAnimation(.easeOut(duration: 0.2)) { keyOpen.toggle() } }
                    }
                }
                if keyOpen && !model.hasLiveKey {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").foregroundColor(.cbWarning)
                            Text("Your session key gives full access to your Claude account. Unofficial address, can stop working any time. Kept in Keychain, sent only to claude.ai.")
                                .font(.system(size: 11)).foregroundColor(Color(hex: 0xD1D1D6)).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            SecureField("sessionKey", text: $key)
                                .textFieldStyle(.plain).font(.system(size: 12))
                                .padding(.horizontal, 8).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                            Button("I understand, turn on") {
                                model.saveLiveKey(key)
                                key = ""
                                keyOpen = false
                            }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.cbAction))
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(12)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
        }
        // Cloud doesn't peek while the key is being typed.
        .onChange(of: keyOpen && !model.hasLiveKey) { open in mood?.shy = open }
        .onDisappear { mood?.shy = false }
    }
}
