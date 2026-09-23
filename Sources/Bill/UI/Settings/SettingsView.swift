import SwiftUI

/// Built without `@State`/`@Observable` — this toolchain's Command Line
/// Tools install can't resolve the `SwiftUIMacros` plugin those macros need
/// (see `ChatBridge`'s doc comment), so state flows through classic
/// `ObservableObject`/`@Published` via `@ObservedObject` instead.
///
/// This is the "proper app to edit more things" surface: Bill's look
/// (accent colour, text size, chat width), his pacing (ambient animation
/// spacing, prompt cadence), per-trigger animation overrides, and the
/// prompt/persona editor — everything the user asked to be able to touch.
struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var memoryStore: MemoryStore
    var onSignOut: () -> Void
    var onResetMemory: () -> Void

    /// The dialogue keys offered as animation-override triggers — the ones
    /// with real pool content behind them. Deliberately curated: the full
    /// key space (battery.35, clock.2130, …) would drown the picker.
    private static let animationTriggers: [(key: String, label: String)] = [
        ("batteryLow", "Low battery"),
        ("batteryCharging", "Plugged in"),
        ("cpuHot", "Mac runs hot"),
        ("networkLost", "Wi-Fi drops"),
        ("networkRestored", "Wi-Fi returns"),
        ("volume.100", "Volume maxed"),
        ("volume.mute", "Volume muted"),
        ("volume.unmute", "Volume unmuted"),
        ("userReturned", "You come back"),
        ("grabbed", "Bill gets grabbed"),
        ("dropped", "Bill gets dropped"),
        ("poked", "Bill gets poked"),
        ("coding", "Coding apps"),
        ("gaming", "Games"),
        ("browsing", "Browsing"),
        ("music", "Music"),
        ("creative", "Creative apps"),
        ("finder", "Finder"),
        ("communication", "Chat & mail"),
        ("productivity", "Work & school"),
        ("aiChat", "Other AI chats"),
        ("tinkering", "Tinkering tools"),
        ("weather.rain", "It rains"),
        ("weather.clear", "Clear skies"),
        ("weather.thunder", "A storm rolls in"),
    ]

    var body: some View {
        Form {
            Section("Appearance") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bill's size")
                        Slider(value: $preferences.characterScale, in: AppPreferences.characterScaleRange, step: 0.05)
                        Text(String(format: "%.0f%%", preferences.characterScale * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                HStack {
                    Text("Bubble colour")
                    Spacer()
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { Color(nsColor: BillPalette.bubbleAccent) },
                            set: { nsColor in
                                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                                NSColor(nsColor).usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                                preferences.bubbleAccentColorHex = String(
                                    format: "%02x%02x%02x",
                                    Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())
                                )
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: 60)
                }
                HStack {
                    Text("Speech text size")
                    Slider(value: $preferences.bubbleTextScale, in: AppPreferences.bubbleTextScaleRange, step: 0.05)
                    Text(String(format: "%.0f%%", preferences.bubbleTextScale * 100))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Text("Chat window width")
                    Slider(value: $preferences.chatBubbleMaxWidth, in: AppPreferences.chatBubbleMaxWidthRange, step: 20)
                    Text("\(Int(preferences.chatBubbleMaxWidth))pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }

            Section("Behaviour") {
                Toggle("Bill roams the screen", isOn: $preferences.isRoamingEnabled)
                Toggle("Minimize-button mischief", isOn: $preferences.isMinimizeMischiefEnabled)
                Text("Occasionally leaps onto a background window's yellow button and actually minimizes it, then falls. Never touches the window you're working in.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Launch Bill at login",
                    isOn: Binding(
                        get: { preferences.launchAtLoginStatus == .enabled },
                        set: { preferences.setLaunchAtLogin($0) }
                    )
                )
                VStack(alignment: .leading, spacing: 4) {
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
                Divider()
                Toggle("Let Bill read window titles", isOn: $preferences.isWindowAwarenessEnabled)
                Text("Lets Bill tell \"Classroom\" from \"Classroom, the to-do list\". Needs the Accessibility permission — without it he simply says nothing extra.")
                    .font(.caption).foregroundStyle(.secondary)
                if preferences.isWindowAwarenessEnabled, !WindowTitleReader.isTrusted {
                    Button("Grant Accessibility Permission…") { WindowTitleReader.requestTrust() }
                }
                Toggle("Also read window contents (screenshot + OCR)", isOn: $preferences.isScreenOCREnabled)
                    .disabled(!preferences.isWindowAwarenessEnabled)
                Text("Deeper awareness — periodically captures just the focused window and reads it on-device. Needs Screen Recording, which must be re-granted after every rebuild because this app is ad-hoc signed.")
                    .font(.caption).foregroundStyle(.secondary)
                if preferences.isScreenOCREnabled, !ScreenTextReader.hasPermission {
                    Button("Grant Screen Recording Permission…") { ScreenTextReader.requestPermission() }
                }
            }

            Section("Animation") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("How long until the next idle animation")
                        Slider(value: $preferences.ambientAnimationSpacing, in: AppPreferences.ambientAnimationSpacingRange, step: 0.05)
                    }
                    HStack {
                        Text("Twitchy").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Lazy").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Per-trigger animations — pin any reaction to a favourite move:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Self.animationTriggers, id: \.key) { trigger in
                    Picker(trigger.label, selection: animationBinding(for: trigger.key)) {
                        Text("Automatic").tag("")
                        ForEach(BillState.allCases, id: \.self) { state in
                            Text(state.rawValue).tag(state.rawValue)
                        }
                    }
                }
            }

            Section("Prompts") {
                Stepper(
                    "Refresh Bill's lines \(preferences.promptRefreshesPerDay)x per day",
                    value: $preferences.promptRefreshesPerDay,
                    in: AppPreferences.promptRefreshesPerDayRange
                )
                Text("Spread across the day, each refresh asks ChatGPT for fresh quips about what you've been doing — never while you're mid-conversation with him.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra persona instructions")
                        .font(.caption.weight(.medium))
                    TextEditor(text: $preferences.promptExtraInstructions)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 84)
                        .border(Color.secondary.opacity(0.25))
                    Text("Appended to every prompt — chat, line refreshes, and app personalization. E.g. \"call me Pine Tree\", \"mention the journals more\", \"no emoji\".")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("Reactions") {
                ForEach(AppCategory.allCases, id: \.self) { category in
                    Toggle(category.displayName, isOn: preferences.binding(for: category))
                }
            }

            Section("Chat") {
                Button("Sign out of ChatGPT", action: onSignOut)
            }

            Section("Memory") {
                Text("Bill has known you for \(memoryStore.daysKnown) day\(memoryStore.daysKnown == 1 ? "" : "s").")
                    .foregroundStyle(.secondary)
                Button("Reset memory", action: onResetMemory)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
    }

    /// `""` (Automatic) when unset, so the picker reads honestly.
    private func animationBinding(for key: String) -> Binding<String> {
        Binding(
            get: { preferences.customAnimationMap[key] ?? "" },
            set: { rawValue in
                var map = preferences.customAnimationMap
                if rawValue.isEmpty {
                    map.removeValue(forKey: key)
                } else {
                    map[key] = rawValue
                }
                preferences.customAnimationMap = map
            }
        )
    }
}
