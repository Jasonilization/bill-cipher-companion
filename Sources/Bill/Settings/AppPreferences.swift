import Foundation
import Combine
import ServiceManagement
import SwiftUI

/// User-facing toggles, persisted to `UserDefaults` — no API key field here,
/// there's nothing to manage since chat goes through the user's own logged-
/// in ChatGPT session.
@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let roaming = "billRoamingEnabled"
        static let disabledCategories = "billDisabledCategories"
        static let adLib = "billAdLibEnabled"
        static let characterScale = "billCharacterScale"
        static let speakingFrequency = "billSpeakingFrequency"
    }

    @Published var isRoamingEnabled: Bool {
        didSet { UserDefaults.standard.set(isRoamingEnabled, forKey: Keys.roaming) }
    }

    @Published var disabledCategories: Set<AppCategory> {
        didSet {
            UserDefaults.standard.set(disabledCategories.map(\.rawValue), forKey: Keys.disabledCategories)
        }
    }

    /// Off by default: routing ambient commentary through the chat bridge
    /// has real latency/cost, unlike the free, instant local bark lines.
    @Published var isAdLibEnabled: Bool {
        didSet { UserDefaults.standard.set(isAdLibEnabled, forKey: Keys.adLib) }
    }

    /// Multiplies Bill's base on-screen size — `BillRigNode.displayScale`
    /// is the 1.0 baseline this scales from. Clamped to a sane range so a
    /// bad persisted value (or a stray slider drag) can't make him
    /// disappear to a pixel or take over the whole screen.
    @Published var characterScale: Double {
        didSet {
            let clamped = min(max(characterScale, Self.characterScaleRange.lowerBound), Self.characterScaleRange.upperBound)
            if clamped != characterScale { characterScale = clamped; return }
            UserDefaults.standard.set(characterScale, forKey: Keys.characterScale)
        }
    }
    static let characterScaleRange: ClosedRange<Double> = 0.5...2.0

    /// Multiplies how often Bill fires an ambient idle beat/bark — see
    /// `CharacterEngine.scheduleNextIdleBeat`'s use of this. 1.0 is the
    /// existing baseline cadence; lower is quieter, higher is chattier.
    @Published var speakingFrequency: Double {
        didSet {
            let clamped = min(max(speakingFrequency, Self.speakingFrequencyRange.lowerBound), Self.speakingFrequencyRange.upperBound)
            if clamped != speakingFrequency { speakingFrequency = clamped; return }
            UserDefaults.standard.set(speakingFrequency, forKey: Keys.speakingFrequency)
        }
    }
    static let speakingFrequencyRange: ClosedRange<Double> = 0.25...2.5

    @Published private(set) var launchAtLoginStatus: SMAppService.Status

    init() {
        let defaults = UserDefaults.standard
        isRoamingEnabled = (defaults.object(forKey: Keys.roaming) as? Bool) ?? true
        isAdLibEnabled = (defaults.object(forKey: Keys.adLib) as? Bool) ?? false
        let disabledRaw = defaults.stringArray(forKey: Keys.disabledCategories) ?? []
        disabledCategories = Set(disabledRaw.compactMap(AppCategory.init(rawValue:)))
        let storedScale = (defaults.object(forKey: Keys.characterScale) as? Double) ?? 1.0
        characterScale = min(max(storedScale, Self.characterScaleRange.lowerBound), Self.characterScaleRange.upperBound)
        let storedFrequency = (defaults.object(forKey: Keys.speakingFrequency) as? Double) ?? 1.0
        speakingFrequency = min(max(storedFrequency, Self.speakingFrequencyRange.lowerBound), Self.speakingFrequencyRange.upperBound)
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func isCategoryEnabled(_ category: AppCategory) -> Bool {
        !disabledCategories.contains(category)
    }

    func setCategory(_ category: AppCategory, enabled: Bool) {
        if enabled {
            disabledCategories.remove(category)
        } else {
            disabledCategories.insert(category)
        }
    }

    func binding(for category: AppCategory) -> Binding<Bool> {
        Binding(
            get: { self.isCategoryEnabled(category) },
            set: { self.setCategory(category, enabled: $0) }
        )
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("AppPreferences: failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }
}
