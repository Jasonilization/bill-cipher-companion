import SwiftUI

/// A proper macOS Settings experience: sidebar on the left with category
/// icons, detail pane on the right — the same visual pattern as System
/// Settings. Built without `@State` (toolchain constraint): the selected
/// section is tracked in the preferences model.
struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var memoryStore: MemoryStore
    var onSignOut: () -> Void
    var onResetMemory: () -> Void
    var onTestWeather: (() -> Void)?
    var onOpenQuotesManager: (() -> Void)?
    var onTestTrigger: ((_ keys: [String], _ animationKey: String) -> Void)?
    /// Switches the on-screen character — AppDelegate wires this to
    /// `switchCharacter(to:)`.
    var onSwitchCharacter: ((_ id: String) -> Void)?
    /// Deltarune world mode changed — AppDelegate wires this to the
    /// engine's crossfade transition.
    var onWorldModeChanged: (() -> Void)?

    enum Section: String, CaseIterable, Identifiable {
        case characters = "Characters"
        case appearance = "Appearance"
        case behaviour = "Behaviour"
        case animations = "Animations"
        case triggers = "Test Triggers"
        case chat = "Chat & Prompts"
        case weather = "Weather"
        case about = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .characters: return "person.2"
            case .appearance: return "paintbrush"
            case .behaviour: return "gearshape"
            case .animations: return "figure.dance"
            case .triggers: return "bolt"
            case .chat: return "bubble.left.and.bubble.right"
            case .weather: return "cloud.sun"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 720, minHeight: 500)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ForEach(Section.allCases) { section in
                sidebarButton(section)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarButton(_ section: Section) -> some View {
        Button(action: { preferences.selectedSettingsSection = section.rawValue }) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .frame(width: 24)
                    .foregroundStyle(isSelected(section) ? Color.accentColor : .secondary)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected(section) ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected(section) ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ section: Section) -> Bool {
        preferences.selectedSettingsSection == section.rawValue
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            switch Section(rawValue: preferences.selectedSettingsSection) ?? .appearance {
            case .characters: charactersDetail
            case .appearance: appearanceDetail
            case .behaviour: behaviourDetail
            case .animations: animationsDetail
            case .triggers: triggersDetail
            case .chat: chatDetail
            case .weather: weatherDetail
            case .about: aboutDetail
            }
        }
    }

    // MARK: - Appearance

    private var appearanceDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Appearance", subtitle: "How Bill looks on your desktop")

            card("Window layer") {
                Toggle("Stay above app windows", isOn: $preferences.isAlwaysOnTop)
                Text("Off = apps can cover your companion. They wander behind windows, hide, and stroll back out.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            card("Character") {
                HStack {
                    Text("Bill's size")
                    Slider(value: $preferences.characterScale, in: AppPreferences.characterScaleRange, step: 0.05)
                    Text(String(format: "%.0f%%", preferences.characterScale * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 50)
                }
                Toggle("Dark mode chrome", isOn: $preferences.isDarkModeChrome)
                Text("Uses a darker fill inside the pixel borders for the chat window and bark panels — better for dark desktops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            card("Speech Bubbles") {
                bubblePreview
                HStack {
                    Text("Bubble colour")
                    Spacer()
                    ColorPicker("", selection: accentBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 60)
                }
                HStack {
                    Text("Text size")
                    Slider(value: $preferences.bubbleTextScale, in: AppPreferences.bubbleTextScaleRange, step: 0.05)
                    Text(String(format: "%.0f%%", preferences.bubbleTextScale * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 50)
                }
                HStack {
                    Text("Chat width")
                    Slider(value: $preferences.chatBubbleMaxWidth, in: AppPreferences.chatBubbleMaxWidthRange, step: 20)
                    Text("\(Int(preferences.chatBubbleMaxWidth))pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 50)
                }
                Text("Changes apply on the next speech bubble.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Behaviour

    private var behaviourDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Behaviour", subtitle: "What Bill does on his own")

            card("Activity") {
                Toggle("Bill roams the screen", isOn: $preferences.isRoamingEnabled)
                Toggle("Minimize-button mischief", isOn: $preferences.isMinimizeMischiefEnabled)
                Toggle("Push windows aside", isOn: $preferences.isWindowPushingEnabled)
                if preferences.isWindowPushingEnabled {
                    Text("Walking across an app window nudges it a few points aside — never the app you're using, and it needs the Accessibility permission. Off, on, and back on: it stops the instant you drag a window yourself.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Toggle("Launch Bill at login", isOn: Binding(
                    get: { preferences.launchAtLoginStatus == .enabled },
                    set: { preferences.setLaunchAtLogin($0) }
                ))
            }

            card("Speech frequency") {
                HStack {
                    Text("How often Bill speaks")
                    Slider(value: $preferences.speakingFrequency, in: AppPreferences.speakingFrequencyRange, step: 0.05)
                }
                HStack {
                    Text("Quiet").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Chatty").font(.caption).foregroundStyle(.secondary)
                }
            }

            card("Awareness") {
                Toggle("Read window titles", isOn: $preferences.isWindowAwarenessEnabled)

                // Permission status — the #1 reason "nothing works": ad-hoc
                // signing invalidates Accessibility on every rebuild, and
                // the user has no way to tell without this indicator.
                if preferences.isWindowAwarenessEnabled {
                    if WindowTitleReader.isTrusted {
                        Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Accessibility NOT granted — Bill can't see window titles", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Button("Grant Accessibility Permission…") { WindowTitleReader.requestTrust() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                Toggle("Read window contents (OCR)", isOn: $preferences.isScreenOCREnabled)
                    .disabled(!preferences.isWindowAwarenessEnabled)

                if preferences.isScreenOCREnabled {
                    if ScreenTextReader.hasPermission {
                        Label("Screen Recording granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Screen Recording NOT granted — OCR can't capture", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Button("Grant Screen Recording…") { ScreenTextReader.requestPermission() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                Text("⚠ Because this app is ad-hoc signed (not notarized), macOS invalidates these permissions on every rebuild. You must re-grant them after each build. This is the #1 reason reactions stop working.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Animations

    /// True when the active character's sheet carries both world forms
    /// (any family mentioning dark or light) — the Deltarune cast.
    private var hasWorldVariants: Bool {
        let id = preferences.activeCharacterID
        struct Entry: Codable { let families: [String: Int] }
        guard let url = Bundle.module.url(
            forResource: "packs_manifest", withExtension: "json", subdirectory: "Packs"
        ), let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode([String: Entry].self, from: data),
              let fams = manifest[id]?.families.keys
        else { return false }
        let hasDark = fams.contains { $0.contains("dark") }
        let hasLight = fams.contains { $0.contains("light") }
        return hasDark && hasLight
    }

    /// The character whose sheet the animation browser is showing —
    /// independent of who is on screen (defaults to the active one).
    private var browsedCharacterBinding: Binding<String> {
        Binding(
            get: {
                preferences.previewCharacterID.isEmpty
                    ? preferences.activeCharacterID
                    : preferences.previewCharacterID
            },
            set: { preferences.previewCharacterID = $0 }
        )
    }

    /// World-mode picker binding — persists and triggers the crossfade.
    private var worldModeBinding: Binding<String> {
        Binding(
            get: { preferences.worldModeMap[preferences.activeCharacterID] ?? "light" },
            set: { newValue in
                var map = preferences.worldModeMap
                let old = map[preferences.activeCharacterID] ?? "light"
                map[preferences.activeCharacterID] = newValue
                preferences.worldModeMap = map
                if old != newValue {
                    onWorldModeChanged?()
                }
            }
        )
    }

    private var animationsDetail: some View {        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Animations", subtitle: "Every animation on the sheet — preview it, assign it to any trigger")

            card("Animation browser") {
                VStack(alignment: .leading, spacing: 8) {
                    // Browse ANY character's sheet — not just whoever is on
                    // screen. The pickers (Facing / World / Assign to…)
                    // write per-family labels that apply wherever that
                    // family plays.
                    Picker("Character", selection: browsedCharacterBinding) {
                        ForEach(CharacterRoster.all) { character in
                            Text(character.displayName).tag(character.id)
                        }
                    }
                    .frame(maxWidth: 360)
                    AnimationBrowserView(
                        characterID: browsedCharacterBinding.wrappedValue,
                        customFamilyMap: $preferences.customFamilyMap,
                        familyFacingMap: $preferences.familyFacingMap,
                        familyWorldMap: $preferences.familyWorldMap
                    )
                    .frame(height: 360)
                }
            }

            // Deltarune (and any character carrying both forms' rows):
            // pick which world's art plays — with a real transition, not
            // a texture pop.
            if hasWorldVariants {
                card("World mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Which world's sprites to use — the character fades between worlds rather than popping.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("World", selection: worldModeBinding) {
                            Text("Light world").tag("light")
                            Text("Dark world").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }
                }
            }

            card("Idle pacing") {
                HStack {
                    Text("Time between idle animations")
                    Slider(value: $preferences.ambientAnimationSpacing, in: AppPreferences.ambientAnimationSpacingRange, step: 0.05)
                }
                HStack {
                    Text("Twitchy").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Lazy").font(.caption).foregroundStyle(.secondary)
                }
            }

            card("Animation selector") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Click an animation to enable or disable it — disabled ones are greyed out and never play automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                            ForEach(BillState.allCases, id: \.self) { state in
                                StateSelectorTile(
                                    state: state,
                                    isEnabled: !preferences.disabledStateIDs.contains(state.rawValue),
                                    onToggle: { enabled in
                                        var current = preferences.disabledStateIDs
                                        if enabled {
                                            current.remove(state.rawValue)
                                        } else {
                                            current.insert(state.rawValue)
                                        }
                                        preferences.disabledStateIDs = current
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 340)
                    HStack {
                        Button("Enable all") {
                            preferences.disabledStateIDs = []
                        }
                        Button("Disable all rare & dramatic") {
                            preferences.disabledStateIDs = Set([
                                "powerSurge", "zodiacVision", "summonRitual", "ritualBuildup",
                                "zodiacRage", "prismDance", "zodiacCrimson", "ghostPale",
                                "glitchForm", "shadowHands", "meltdown", "rampaging",
                            ])
                        }
                    }
                }
            }

            card("Per-trigger animations") {
                ForEach(Self.animationTriggers, id: \.key) { trigger in
                    Picker(trigger.label, selection: animationBinding(for: trigger.key)) {
                        Text("Automatic").tag("")
                        ForEach(BillState.allCases, id: \.self) { state in
                            Text(state.rawValue).tag(state.rawValue)
                        }
                    }
                    .frame(maxWidth: 400)
                }
            }

            card("Per-app animations") {
                let apps = memoryStore.knownApps()
                if apps.isEmpty {
                    Text("Open a few apps and Bill will list them here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(apps.prefix(20), id: \.bundleID) { app in
                        Picker(app.name, selection: perAppBinding(for: app.bundleID)) {
                            Text("Automatic").tag("")
                            ForEach(BillState.allCases, id: \.self) { state in
                                Text(state.rawValue).tag(state.rawValue)
                            }
                        }
                        .frame(maxWidth: 400)
                    }
                }
            }
            Spacer()
        }
        .padding(24)
    }

    static let animationTriggers: [(key: String, label: String)] = [
        ("batteryLow", "Low battery"), ("batteryCharging", "Plugged in"),
        ("cpuHot", "Mac runs hot"), ("networkLost", "Wi-Fi drops"),
        ("networkRestored", "Wi-Fi returns"), ("volume.100", "Volume maxed"),
        ("volume.mute", "Volume muted"), ("userReturned", "You come back"),
        ("grabbed", "Bill gets grabbed"), ("dropped", "Bill gets dropped"),
        ("poked", "Bill gets poked"), ("coding", "Coding"),
        ("gaming", "Games"), ("browsing", "Browsing"),
        ("music", "Music"), ("creative", "Creative"),
        ("finder", "Finder"), ("communication", "Chat & mail"),
        ("productivity", "Work"), ("aiChat", "Other AI"),
    ]

    // MARK: - Test Triggers

    private var triggersDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Test Triggers", subtitle: "Fire any reaction live to verify it works")

            card("Reaction triggers") {
                Text("Press any button — Bill should react on your desktop immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 8) {
                    ForEach(Self.testTriggersList, id: \.key) { trigger in
                        Button(trigger.label) {
                            onTestTrigger?([trigger.key], trigger.key)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Button("Test Weather") { onTestWeather?() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
            Spacer()
        }
        .padding(24)
    }

    static let testTriggersList: [(key: String, label: String)] = [
        ("batteryLow", "Low Battery"), ("networkLost", "Wi-Fi Drops"),
        ("networkRestored", "Wi-Fi Back"), ("volume.100", "Volume Up"),
        ("volume.mute", "Volume Mute"), ("poked", "Poke"),
        ("chatFailed", "Chat Error"), ("stillThinking", "Thinking"),
        ("incognito.search", "Incognito"), ("deal.offer", "Deal Offer"),
        ("cipher.message", "Cipher"), ("userReturned", "User Returns"),
        ("clock.morning", "Morning"), ("clock.night", "Night"),
        ("weather.rain", "Rain"), ("weather.clear", "Clear Sky"),
    ]

    // MARK: - Chat & Prompts

    private var chatDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Chat & Prompts", subtitle: "Dialogue management and persona")

            card("Quotes") {
                Button("Open the Quotes Manager…") { onOpenQuotesManager?() }
                Text("Every pool, every line, where each came from — plus one-click refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            card("Refresh cadence") {
                Stepper(
                    "Refresh Bill's lines \(preferences.promptRefreshesPerDay)x per day",
                    value: $preferences.promptRefreshesPerDay,
                    in: AppPreferences.promptRefreshesPerDayRange
                )
                Text("Spread across the day, never while you're mid-conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            card("Extra persona instructions") {
                TextEditor(text: $preferences.promptExtraInstructions)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 84)
                    .frame(maxWidth: 480)
                Text("Appended to every prompt — e.g. \"call me Pine Tree\", \"mention the journals more\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            card("Chat account") {
                Button("Sign out of ChatGPT", action: onSignOut)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Weather

    private var weatherDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Weather", subtitle: "Bill comments on the sky")

            card("Weather commentary") {
                Toggle("Bill talks about the weather", isOn: $preferences.isWeatherEnabled)
                Stepper(
                    preferences.weatherAnnounceMinutes == 0
                        ? "Report only on changes"
                        : "Mention current weather every \(preferences.weatherAnnounceMinutes) min",
                    value: $preferences.weatherAnnounceMinutes,
                    in: AppPreferences.weatherAnnounceRange,
                    step: 15
                )
                Text("Pulls keyless Open-Meteo nowcast every 5 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Test weather now") { onTestWeather?() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
            Spacer()
        }
        .padding(24)
    }


    // MARK: - Characters

    /// The pack system's front door in Settings: pick who's on screen, who
    /// stands beside them, and *watch* each animation before committing —
    /// the preview is a real SpriteKit view running the same
    /// `CharacterAnimationLibrary` clips the desktop character plays.
    private var charactersDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Characters", subtitle: "Who lives on your desktop — and who they bring along")

            card("On screen now") {
                VStack(alignment: .leading, spacing: 12) {
                    let current = CharacterRoster.character(preferences.activeCharacterID)
                    HStack {
                        Text("Active character")
                        Spacer()
                        Text(current.displayName + " — " + current.packName)
                            .foregroundColor(.secondary)
                    }
                    characterGrid
                }
            }

            // "Hollow Knight enemies" card REMOVED: the row-sliced enemy
            // sprites were garbage frames and are hidden from the roster
            // until properly labeled in the Sprite Workbench. The spawn
            // controller no-ops safely with an empty enemy roster.

            card("Companions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Show alongside " + CharacterRoster.character(preferences.activeCharacterID).displayName)
                        .foregroundColor(.secondary)
                    let packCharacters = CharacterRoster.all.filter {
                        !$0.isBill && $0.id != preferences.activeCharacterID
                    }
                    if packCharacters.isEmpty {
                        Text("This character flies solo.")
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(packCharacters) { companion in
                                    HStack {
                                        Toggle(companion.displayName, isOn: companionBinding(companion.id))
                                        if preferences.activeCompanionIDs.contains(companion.id) {
                                            Toggle("", isOn: muteBinding(companion.id))
                                                .help("Mute: this companion animates but never speaks")
                                                .frame(width: 60)
                                            Text("mute").font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(height: 240)
                        Text("Leave everything unchecked to use the pack's default pair.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            card("Animation preview") {
                CharacterPreviewView(characterID: preferences.previewCharacterID.isEmpty
                    ? preferences.activeCharacterID
                    : preferences.previewCharacterID)
            }

            if !currentCredit.isEmpty {
                card("Sprite credit") {
                    Text(currentCredit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
    }

    /// One tile per character, grouped by pack — click to switch, watch the
    /// preview update live.
    private var characterGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                characterTile(CharacterRoster.bill)
            }
            ForEach(CharacterRoster.packs, id: \.name) { pack in
                VStack(alignment: .leading, spacing: 6) {
                    Text(pack.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(pack.characters) { character in
                            characterTile(character)
                        }
                    }
                }
            }
        }
    }

    private func characterTile(_ character: CharacterDefinition) -> some View {
        Button {
            preferences.activeCharacterID = character.id
            preferences.previewCharacterID = character.id
            onSwitchCharacter?(character.id)
        } label: {
            Text(character.displayName)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(preferences.activeCharacterID == character.id
                      ? Color.accentColor.opacity(0.25)
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(preferences.activeCharacterID == character.id ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private func stateEnabledBinding(_ raw: String) -> Binding<Bool> {
        Binding(
            get: { !preferences.disabledStateIDs.contains(raw) },
            set: { enabled in
                var current = preferences.disabledStateIDs
                if enabled {
                    current.remove(raw)
                } else {
                    current.insert(raw)
                }
                preferences.disabledStateIDs = current
            }
        )
    }

    private func muteBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !preferences.mutedCompanionIDs.contains(id) },
            set: { canTalk in
                var current = preferences.mutedCompanionIDs
                if canTalk {
                    current.remove(id)
                } else {
                    current.insert(id)
                }
                preferences.mutedCompanionIDs = current
            }
        )
    }

    private func companionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { preferences.activeCompanionIDs.contains(id) },
            set: { included in
                var current = preferences.activeCompanionIDs
                if included {
                    if !current.contains(id) { current.append(id) }
                } else {
                    current.removeAll { $0 == id }
                }
                preferences.activeCompanionIDs = current
                onSwitchCharacter?(preferences.activeCharacterID)
            }
        )
    }

    private var currentCredit: String {
        CharacterRoster.character(preferences.activeCharacterID).credit
    }

    // MARK: - About

    private var aboutDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("About", subtitle: "")

            card("") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bill Cipher — Desktop Companion")
                        .font(.title2.weight(.semibold))
                    Text("Version 1.0.0")
                        .foregroundStyle(.secondary)
                }
            }

            card("Memory") {
                Text("Bill has known you for \(memoryStore.daysKnown) day\(memoryStore.daysKnown == 1 ? "" : "s").")
                    .foregroundStyle(.secondary)
                Button("Reset memory", action: onResetMemory)
            }

            card("Credits") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bill Cipher sprite artwork")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Original artwork: Kelly Nora (@kiernenking)")
                    Text("Sprite sheet: JayHyperstarX — DeviantArt")
                    if let url = URL(string: "https://www.deviantart.com/jayhyperstarx/art/Bill-Cipher---Sprite-Sheet-910916786") {
                        Link("deviantart.com/jayhyperstarx", destination: url)
                            .font(.system(size: 11))
                    }
                    Text("Unofficial, non-commercial fan project. Bill Cipher and Gravity Falls are © Disney. Code is MIT.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .font(.system(size: 11))
                .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - UI helpers

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var bubblePreview: some View {
        let image = BarkBubble.makePreviewImage(text: "HELLO, PINE TREE.")
        let scale = BarkBubble.effectivePixelScale
        return Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .frame(width: image.size.width * scale, height: image.size.height * scale)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: BillPalette.bubbleAccent) },
            set: { nsColor in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                NSColor(nsColor).usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                preferences.bubbleAccentColorHex = String(
                    format: "%02x%02x%02x",
                    Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())
                )
            }
        )
    }

    private func animationBinding(for key: String) -> Binding<String> {
        Binding(
            get: { preferences.customAnimationMap[key] ?? "" },
            set: { rawValue in
                var map = preferences.customAnimationMap
                if rawValue.isEmpty { map.removeValue(forKey: key) }
                else { map[key] = rawValue }
                preferences.customAnimationMap = map
            }
        )
    }

    private func perAppBinding(for bundleID: String) -> Binding<String> {
        Binding(
            get: { preferences.perAppAnimations[bundleID] ?? "" },
            set: { rawValue in
                var map = preferences.perAppAnimations
                if rawValue.isEmpty { map.removeValue(forKey: bundleID) }
                else { map[bundleID] = rawValue }
                preferences.perAppAnimations = map
            }
        )
    }
}
