import SwiftUI

/// Built without `@State`/`@Observable` — this toolchain's Command Line
/// Tools install can't resolve the `SwiftUIMacros` plugin those macros need
/// (see `ChatBridge`'s doc comment), so state flows through classic
/// `ObservableObject`/`@Published` via `@ObservedObject` instead.
struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var memoryStore: MemoryStore
    var onSignOut: () -> Void
    var onResetMemory: () -> Void

    var body: some View {
        Form {
            Section("Appearance") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Size")
                        Slider(value: $preferences.characterScale, in: AppPreferences.characterScaleRange, step: 0.05)
                        Text(String(format: "%.0f%%", preferences.characterScale * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Bill roams the screen", isOn: $preferences.isRoamingEnabled)
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
                Toggle("Let Bill ad-lib idle commentary through chat", isOn: $preferences.isAdLibEnabled)
                Text("Ad-libbing routes occasional idle commentary through the chat bridge instead of local one-liners — off by default since it has real latency and isn't free.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 420, height: 480)
    }
}
