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
        static let minimizeMischief = "billMinimizeMischief"
        static let bubbleAccentColor = "billBubbleAccentColor"
        static let bubbleTextScale = "billBubbleTextScale"
        static let chatBubbleMaxWidth = "billChatBubbleMaxWidth"
        static let ambientAnimationSpacing = "billAmbientAnimationSpacing"
        static let customAnimationMap = "billCustomAnimationMap"
        static let promptRefreshesPerDay = "billPromptRefreshesPerDay"
        static let promptExtraInstructions = "billPromptExtraInstructions"
        static let weatherEnabled = "billWeatherEnabled"
        static let weatherAnnounceMinutes = "billWeatherAnnounceMinutes"
    }

    @Published var isRoamingEnabled: Bool {
        didSet { UserDefaults.standard.set(isRoamingEnabled, forKey: Keys.roaming) }
    }

    /// Bill's occasional prank: leap up and press a window's minimize
    /// button — actually minimizing it — to play with you. On by default
    /// (it is rare and harmless); the user explicitly asked for a way to
    /// disable the mode, and this is that switch.
    @Published var isMinimizeMischiefEnabled: Bool {
        didSet { UserDefaults.standard.set(isMinimizeMischiefEnabled, forKey: Keys.minimizeMischief) }
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

    // MARK: - Look & feel (the "proper app to edit more things" set)

    /// Hex string, no leading `#` — parsed into the live accent color at
    /// `BillPalette`. Default is Bill's canon yellow.
    @Published var bubbleAccentColorHex: String {
        didSet { UserDefaults.standard.set(bubbleAccentColorHex, forKey: Keys.bubbleAccentColor) }
    }
    /// Multiplies the bark bubble's pixel scale — grows/shrinks the *text*
    /// and its bubble together, crisp at any value (nearest-neighbor).
    @Published var bubbleTextScale: Double {
        didSet { UserDefaults.standard.set(bubbleTextScale, forKey: Keys.bubbleTextScale) }
    }
    static let bubbleTextScaleRange: ClosedRange<Double> = 0.6...2.4
    /// The pixel chat panel's max width in points.
    @Published var chatBubbleMaxWidth: Double {
        didSet { UserDefaults.standard.set(chatBubbleMaxWidth, forKey: Keys.chatBubbleMaxWidth) }
    }
    static let chatBubbleMaxWidthRange: ClosedRange<Double> = 320...900

    // MARK: - Animation pacing

    /// Multiplies the spacing between ambient idle beats — "how long until
    /// the next one." At 1.0 the base spacing is the original 4-9s roll;
    /// 2.0 makes him lazier, 0.5 twitchier. Deliberately separate from
    /// `speakingFrequency`, which gates *lines*, not motion.
    @Published var ambientAnimationSpacing: Double {
        didSet { UserDefaults.standard.set(ambientAnimationSpacing, forKey: Keys.ambientAnimationSpacing) }
    }
    static let ambientAnimationSpacingRange: ClosedRange<Double> = 0.25...4.0

    /// Per-trigger animation overrides: dialogue-key → `BillState.rawValue`.
    /// The router consults this before its animation pools, so any reaction
    /// can be pinned to a favourite animation. Empty = fully automatic.
    @Published var customAnimationMap: [String: String] {
        didSet { UserDefaults.standard.set(customAnimationMap, forKey: Keys.customAnimationMap) }
    }

    // MARK: - Prompt cadence & persona

    /// How many times a day the ChatGPT dialogue refresh runs. The user's
    /// ask: prompts should refresh *across* the day, not once — this
    /// spreads them evenly (24h / n), still skipping whenever a live chat
    /// or another background request is in flight.
    @Published var promptRefreshesPerDay: Int {
        didSet { UserDefaults.standard.set(promptRefreshesPerDay, forKey: Keys.promptRefreshesPerDay) }
    }
    static let promptRefreshesPerDayRange: ClosedRange<Int> = 1...6
    /// Free-form extra persona instructions appended to every prompt
    /// (chat context, dialogue refresh, personalization) — the user's
    /// handle on exactly how Bill talks to *them*.
    @Published var promptExtraInstructions: String {
        didSet { UserDefaults.standard.set(promptExtraInstructions, forKey: Keys.promptExtraInstructions) }
    }

    // MARK: - Weather

    /// Master switch for all weather commentary. Off means the monitor
    /// doesn't even fetch — no announcement, no chat context blurb.
    @Published var isWeatherEnabled: Bool {
        didSet { UserDefaults.standard.set(isWeatherEnabled, forKey: Keys.weatherEnabled) }
    }
    /// How often (minutes) Bill mentions the current weather *regardless of
    /// change* — the fix for "I never saw him say anything about the
    /// weather": steady-weather days previously meant silence after the
    /// first pull. 0 = off; condition changes always announce anyway.
    @Published var weatherAnnounceMinutes: Int {
        didSet { UserDefaults.standard.set(weatherAnnounceMinutes, forKey: Keys.weatherAnnounceMinutes) }
    }
    static let weatherAnnounceRange: ClosedRange<Int> = 0...240

    @Published private(set) var launchAtLoginStatus: SMAppService.Status

    init() {
        let defaults = UserDefaults.standard
        isRoamingEnabled = (defaults.object(forKey: Keys.roaming) as? Bool) ?? true
        isMinimizeMischiefEnabled = (defaults.object(forKey: Keys.minimizeMischief) as? Bool) ?? true
        isWindowAwarenessEnabled = (defaults.object(forKey: Keys.windowAwareness) as? Bool) ?? false
        isScreenOCREnabled = (defaults.object(forKey: Keys.screenOCR) as? Bool) ?? false
        bubbleAccentColorHex = defaults.string(forKey: Keys.bubbleAccentColor) ?? "fac726"
        let storedTextScale = (defaults.object(forKey: Keys.bubbleTextScale) as? Double) ?? 1.0
        bubbleTextScale = min(max(storedTextScale, Self.bubbleTextScaleRange.lowerBound), Self.bubbleTextScaleRange.upperBound)
        let storedChatWidth = (defaults.object(forKey: Keys.chatBubbleMaxWidth) as? Double) ?? 600
        chatBubbleMaxWidth = min(max(storedChatWidth, Self.chatBubbleMaxWidthRange.lowerBound), Self.chatBubbleMaxWidthRange.upperBound)
        let storedSpacing = (defaults.object(forKey: Keys.ambientAnimationSpacing) as? Double) ?? 1.0
        ambientAnimationSpacing = min(max(storedSpacing, Self.ambientAnimationSpacingRange.lowerBound), Self.ambientAnimationSpacingRange.upperBound)
        customAnimationMap = defaults.dictionary(forKey: Keys.customAnimationMap) as? [String: String] ?? [:]
        promptRefreshesPerDay = (defaults.object(forKey: Keys.promptRefreshesPerDay) as? Int) ?? 3
        promptExtraInstructions = defaults.string(forKey: Keys.promptExtraInstructions) ?? ""
        isWeatherEnabled = (defaults.object(forKey: Keys.weatherEnabled) as? Bool) ?? true
        weatherAnnounceMinutes = min(
            max((defaults.object(forKey: Keys.weatherAnnounceMinutes) as? Int) ?? 60, Self.weatherAnnounceRange.lowerBound),
            Self.weatherAnnounceRange.upperBound
        )
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
