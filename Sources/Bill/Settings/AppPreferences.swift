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
        static let characterScale = "billCharacterScale"
        static let windowAwareness = "billWindowAwareness"
        static let screenOCR = "billScreenOCR"
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


    /// Multiplies Bill's base on-screen size — `BillRigNode.displayScale`
    /// is the 1.0 baseline this scales from. Clamped to a sane range so a
    /// bad persisted value (or a stray slider drag) can't make him
    /// disappear to a pixel or take over the whole screen.
    /// Lets Bill read the *title* of the window you are focused on, so he can
    /// tell "Classroom" from "Classroom, the to-do list". Requires the
    /// Accessibility permission; degrades to silence without it. Off until the
    /// user turns it on, because it is a permission request.
    @Published var isWindowAwarenessEnabled: Bool {
        didSet { UserDefaults.standard.set(isWindowAwarenessEnabled, forKey: Keys.windowAwareness) }
    }

    /// The deeper, more expensive option: periodically capture the focused
    /// window and OCR it. Needs Screen Recording, which — because this app is
    /// ad-hoc signed — has to be re-granted after every rebuild. Off by
    /// default and deliberately separate from the title toggle.
    @Published var isScreenOCREnabled: Bool {
        didSet { UserDefaults.standard.set(isScreenOCREnabled, forKey: Keys.screenOCR) }
    }

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
        isWindowAwarenessEnabled = (defaults.object(forKey: Keys.windowAwareness) as? Bool) ?? false
        isScreenOCREnabled = (defaults.object(forKey: Keys.screenOCR) as? Bool) ?? false
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
