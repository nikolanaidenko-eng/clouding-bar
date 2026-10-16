import SwiftUI

/// The settings window from design/Settings.dc.html (560×560): General and
/// Buttons. Cowork and Stats come with stage 3.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: String

    init(model: AppModel, tab: String = "general") {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MascotIcon(activity: .sleep, size: 26).frame(width: 26, height: 26)
                Text("Clouding Bar").font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 0) {
                    ForEach([("general", "General"), ("buttons", "Buttons"), ("stats", "Stats")], id: \.0) { id, label in
                        Button(label) { withAnimation(.easeOut(duration: 0.18)) { tab = id } }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(tab == id ? Color(hex: 0x636366) : .clear))
                            .accessibilityAddTraits(tab == id ? .isSelected : [])
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
            }
            // Room on the left for the window's close button.
            .padding(.leading, 40).padding(.trailing, 18).padding(.vertical, 14)
            .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5), alignment: .bottom)

            ScrollView {
                Group {
                    switch tab {
                    case "general": GeneralTab(model: model)
                    case "buttons": ButtonsTab(model: model)
                    default: StatsTab()
                    }
                }
                .padding(18)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .foregroundColor(.cbText)
        .frame(width: 560, height: 560)
        .background(Color(hex: 0x232325))
        .environment(\.colorScheme, .dark)
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

struct SettingsRow<Accessory: View>: View {
    let title: String
    var hint: String = ""
    var divider = true
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if !hint.isEmpty { Text(hint).font(.system(size: 11)).foregroundColor(.cbSecondary) }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 12)
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

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @State private var moreOpen = false

    private func binding(_ key: String, _ get: @escaping (Config) -> Bool) -> Binding<Bool> {
        Binding(get: { get(model.config) }, set: { model.setConfig(key, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup {
                SettingsRow(title: "Show on Touch Bar",
                            hint: model.touchBarPresent ? "Detected on this Mac" : "No Touch Bar found on this Mac") {
                    CBSwitch(title: "Show on Touch Bar", on: Binding(
                        get: { model.config.touchBar != "off" },
                        set: { model.setConfig("touchBar", $0 ? (model.touchBarPresent ? "auto" : "on") : "off") }))
                }
                SettingsRow(title: "Floating widget", hint: "A pill at the top of the screen that opens on hover") {
                    CBSwitch(title: "Floating widget", on: binding("widget") { $0.widget })
                }
                SettingsRow(title: "Keep the pill visible", hint: "Off: a thin line until you hover it") {
                    CBSwitch(title: "Keep the pill visible", on: binding("pillAlwaysVisible") { $0.pillAlwaysVisible })
                }
                SettingsRow(title: "Widget position",
                            hint: model.config.widgetPosition == nil ? "Top center, under the menu bar" : "Where you dragged it",
                            divider: model.hasNotch) {
                    Button("Reset") { model.resetWidgetPosition() }
                        .disabled(model.config.widgetPosition == nil)
                }
                if model.hasNotch {
                    SettingsRow(title: "At the notch", hint: "Hang the widget from the camera notch") {
                        CBSwitch(title: "At the notch", on: binding("widgetAtNotch") { $0.widgetAtNotch })
                    }
                }
                SettingsRow(title: "Open at login", divider: false) {
                    CBSwitch(title: "Open at login", on: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                }
            }

            SettingsGroup {
                HStack(spacing: 10) {
                    Text("Always show in pill").font(.system(size: 13))
                    Spacer()
                    ForEach([("context", "Context"), ("reset", "Reset time"), ("cost", "API cost")], id: \.0) { id, label in
                        Chip(label: label, on: model.config.pillShows.contains(id)) {
                            var list = model.config.pillShows
                            if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
                            model.setConfig("pillShows", list)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
            }

            VoiceGroup(model: model)

            SettingsGroup {
                Button { withAnimation(.easeOut(duration: 0.2)) { moreOpen.toggle() } } label: {
                    HStack {
                        Text("More options").font(.system(size: 13))
                        Spacer()
                        Text("\(moreOnCount) on").font(.system(size: 12)).foregroundColor(.cbSecondary)
                        Icon(kind: .chevronRight, size: 12, lineWidth: 2.2).foregroundColor(.cbSecondary)
                            .rotationEffect(.degrees(moreOpen ? 90 : 0))
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if moreOpen {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) {
                        CBCheckbox(title: "Context warning", hint: "\(Int(model.config.contextWarnPercent))%",
                                   on: binding("contextWarning") { $0.contextWarning })
                        CBCheckbox(title: "Auto-compact", hint: "at the warning",
                                   on: binding("autoCompact") { $0.autoCompact })
                        CBCheckbox(title: "Sessions list", on: binding("sessionsList") { $0.sessionsList })
                        CBCheckbox(title: "Do not disturb", on: binding("doNotDisturb") { $0.doNotDisturb })
                        CBCheckbox(title: "Task queue", on: binding("taskQueue") { $0.taskQueue })
                        CBCheckbox(title: "Templates", on: binding("templatesEnabled") { $0.templatesEnabled })
                        CBCheckbox(title: "Screenshot", hint: "button", on: binding("screenshot") { $0.screenshot })
                        metric("cost", "Cost", hint: "API")
                        metric("model", "Model, effort")
                        metric("lines", "Lines changed")
                        metric("git", "Git branch")
                        metric("agents", "Subagents")
                    }
                    .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5), alignment: .top)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
        }
    }

    private var moreOnCount: Int {
        let c = model.config
        return [c.contextWarning, c.autoCompact, c.sessionsList, c.doNotDisturb, c.taskQueue, c.templatesEnabled,
                c.screenshot].filter { $0 }.count + c.metrics.count
    }

    private func metric(_ id: String, _ title: String, hint: String = "") -> some View {
        CBCheckbox(title: title, hint: hint, on: Binding(
            get: { model.config.metrics.contains(id) },
            set: { on in
                var list = model.config.metrics.filter { $0 != id }
                if on { list.append(id) }
                model.setConfig("metrics", list)
            }))
    }
}

/// Dictation language, and whether it works offline on this Mac.
struct VoiceGroup: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Voice", hint: "Hold the right ⌥ key alone, or the widget's mic. Text goes in without Enter.",
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
                TouchBarPreview(labels: list.map(\.label) + (editing && selected == nil ? [draftName.isEmpty ? "New" : draftName] : []),
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
            Text(model.config.templatesEnabled ? "Templates · {project} {branch} {clipboard} {date}"
                 : "Templates · turn on in General → More options")
                .font(.system(size: 11)).foregroundColor(.cbSecondary)
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

/// The small live Touch Bar from the Buttons tab: chips get added, the
/// meters lose their words as room runs out (same rule as the real bar).
struct TouchBarPreview: View {
    let labels: [String]
    var highlightLast = false

    var body: some View {
        let used = labels.reduce(CGFloat(0)) { $0 + min(80, 14 + CGFloat($1.count) * 6.2) + 5 }
        let avail = 512 - 10 - 36 - 14 - 10 - used
        let wide = avail >= 230, mid = avail >= 130
        HStack(spacing: 5) {
            Text("esc").font(.system(size: 10)).frame(width: 36, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: 0x2C2C2E)))
            RoundedRectangle(cornerRadius: 5).fill(Color(hex: 0xECEAE5)).frame(width: 14, height: 12)
            // Session and Context split what the buttons leave, 3 : 2.
            let room = max(0, avail - 8 - 10)
            HStack(spacing: 10) {
                meter(wide ? "Session" : mid ? "5h" : "", value: "42%" + (mid ? " · 1:23" : ""), percent: 0.42)
                    .frame(width: room * 3 / 5)
                meter(wide ? "Context" : mid ? "Ctx" : "", value: "31%", percent: 0.31)
                    .frame(width: room * 2 / 5)
            }
            .padding(.horizontal, 4)
            .animation(.easeOut(duration: 0.3), value: wide)
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                Text(label)
                    .font(.system(size: label.count > 10 ? 9 : 11))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .frame(maxWidth: 80)
                    .fixedSize(horizontal: label.count <= 10, vertical: false)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(highlightLast && i == labels.count - 1 ? Color(hex: 0x0A3D78) : Color(hex: 0x2C2C2E)))
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touch Bar preview: " + labels.joined(separator: ", "))
    }

    private func meter(_ label: String, value: String, percent: CGFloat) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).foregroundColor(.cbSecondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(value).lineLimit(1)
            }
            .font(.system(size: 9).monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: 0x2C2C2E))
                    Capsule().fill(Color.cbFill).frame(width: geo.size.width * percent)
                }
            }
            .frame(height: 3)
        }
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

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            recording = true
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return true
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return false }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            switch event.keyCode {
            case 53: // esc
                window?.makeFirstResponder(nil)
            case 51, 117: // delete
                combo = nil
                onChange?(nil)
                window?.makeFirstResponder(nil)
            default:
                guard let c = HotKeys.combo(from: event) else { NSSound.beep(); return }
                combo = c
                onChange?(c)
                window?.makeFirstResponder(nil)
            }
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
