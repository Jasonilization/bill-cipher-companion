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
        static let perAppAnimations = "billPerAppAnimations"
        static let darkModeChrome = "billDarkModeChrome"
        static let alwaysOnTop = "billAlwaysOnTop"
        static let customFamilyMap = "billCustomFamilyMap"
        static let familyFacingMap = "billFamilyFacingMap"
        static let windowPushing = "billWindowPushing"
        static let worldModeMap = "billWorldModeMap"
        static let familyWorldMap = "billFamilyWorldMap"
        static let mutedCompanions = "billMutedCompanions"
        static let disabledStates = "billDisabledStates"
        static let enemySpawning = "billEnemySpawning"
        static let activeCharacter = "billActiveCharacterID"
        static let activeCompanions = "billActiveCompanionIDs"
    }

    /// The character currently on screen — "bill" (default) or any id from
    /// `CharacterRoster`. Persisted so a relaunch brings the same character
    /// back; menu-bar switching keeps it live.
    /// When on (default) the character floats above app windows — the
    /// classic companion look. When off, the window drops to the normal
    /// level: apps cover the character, so they can wander behind windows
    /// and *hide* — they peek back out when the frontmost app moves.
    @Published var isAlwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(isAlwaysOnTop, forKey: Keys.alwaysOnTop) }
    }

    @Published var activeCharacterID: String {
        didSet { UserDefaults.standard.set(activeCharacterID, forKey: Keys.activeCharacter) }
    }

    /// The companions shown alongside the active character — a user-chosen
    /// subset of the active pack's roster ("for Deltarune you can have all,
    /// only 2, or one"). IDs outside the active pack are ignored at build
    /// time. When empty, a pack's default pair applies (Sans→Papyrus,
    /// Knight→Hornet, Kris→Ralsei).
    /// State → sprite-family override for the active pack character
    /// ("use the Hornet jump whenever music plays"). Keyed by
    /// `BillState.rawValue`, value is a family name from the character's
    /// sheet. Applied on top of the automatic ladder.
    /// The animation SELECTOR/DESELECTOR: states unchecked here never play
    /// from any automatic path (idle beats, rare eggs, showcase, reaction
    /// pools). Manually-triggered test buttons still work.
    @Published var disabledStateIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledStateIDs), forKey: Keys.disabledStates) }
    }

    /// Hollow Knight enemy spawning: when on, enemies from the extracted
    /// pool periodically spawn as flying companions, collide with the
    /// main character, and quip short lines. Cap: 6 simultaneous.
    @Published var isEnemySpawningEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnemySpawningEnabled, forKey: Keys.enemySpawning) }
    }

    /// Companions that don't speak ("who talks" control) — their beats
    /// animate but never bark.
    @Published var mutedCompanionIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(mutedCompanionIDs), forKey: Keys.mutedCompanions) }
    }

    @Published var customFamilyMap: [String: String] {
        didSet { UserDefaults.standard.set(customFamilyMap, forKey: Keys.customFamilyMap) }
    }

    /// Family → facing label ("left" / "right"), set from the animation
    /// browser's per-row Facing picker. "right" on left-authored art
    /// mirrors the family when it plays; "left" pins it un-mirrored;
    /// absent = automatic (roaming direction / sheet's own art).
    @Published var familyFacingMap: [String: String] {
        didSet { UserDefaults.standard.set(familyFacingMap, forKey: Keys.familyFacingMap) }
    }

    /// Character id → "light" / "dark" world mode (Deltarune). The
    /// animation library prefers mode-matching families (dark-world
    /// walk cycles for dark mode, plain/light ones for light mode).
    @Published var worldModeMap: [String: String] {
        didSet { UserDefaults.standard.set(worldModeMap, forKey: Keys.worldModeMap) }
    }

    /// Family → "light" / "dark" world label, set per-row in the
    /// animation browser — THE user-facing mapping of which sheet rows
    /// belong to which world. Takes precedence over name heuristics.
    @Published var familyWorldMap: [String: String] {
        didSet { UserDefaults.standard.set(familyWorldMap, forKey: Keys.familyWorldMap) }
    }

    @Published var activeCompanionIDs: [String] {
        didSet { UserDefaults.standard.set(activeCompanionIDs, forKey: Keys.activeCompanions) }
    }

    /// Whether the debug menu section is exposed at all. Off by default —
    /// debug controls live behind `defaults write <bundle> billDebugMenu -bool YES`
    /// rather than in every user's menu bar.
    static var isDebugMenuEnabled: Bool {
        UserDefaults.standard.bool(forKey: "billDebugMenu")
    }

    @Published var isRoamingEnabled: Bool {
        didSet { UserDefaults.standard.set(isRoamingEnabled, forKey: Keys.roaming) }
    }

    /// Window pushing: walking across an app window nudges it aside via
    /// the Accessibility API. Off by default — it moves real windows;
    /// never the frontmost app's, and inert without the Accessibility
    /// permission.
    @Published var isWindowPushingEnabled: Bool {
        didSet { UserDefaults.standard.set(isWindowPushingEnabled, forKey: Keys.windowPushing) }
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

    /// The selected Settings section — tracked in the model since
    /// `@State` is unavailable in this toolchain.
    @Published var selectedSettingsSection: String = "Characters"

    /// The character whose animations the Settings preview pane is showing
    /// — same reason as above (`@State` unavailable). Empty = follow the
    /// active character.
    @Published var previewCharacterID: String = ""

    /// Shared static for views that can't access the preferences instance
    /// (like `ChatFrameView.draw`). Set by `AppDelegate` at launch and
    /// whenever the preference changes.
    static var isDarkModeChromeShared: Bool = false

    /// The active character id, mirrored for non-observable contexts (the
    /// chat bridge's persona picker). Set at launch and on every switch.
    static var activeCharacterShared: String = "bill"

    /// The state→family assignment table, mirrored for the animation
    /// library (which reads it on every clip build).
    static var customFamilyMapShared: [String: String] = [:]
    static var familyFacingMapShared: [String: String] = [:]
    static var worldModeMapShared: [String: String] = [:]
    static var familyWorldMapShared: [String: String] = [:]
    static var isWindowPushingEnabledShared = false

    /// Muted companions, mirrored for the companion controllers.
    static var mutedCompanionsShared: Set<String> = []

    /// The user-deselected states, mirrored for the engine's ambient gates.
    static var disabledStatesShared: Set<String> = []

    @MainActor static func isStateDisabledShared(_ raw: String) -> Bool {
        disabledStatesShared.contains(raw)
    }

    @MainActor static func isMutedCompanionShared(_ id: String) -> Bool {
        mutedCompanionsShared.contains(id)
    }

    /// Dark mode for the pixel chrome (chat frame, bark panel borders) —
    /// when on, the pixel borders use a darker ink fill so Bill's
    /// chat window doesn't look like a bright rectangle floating in a
    /// dark environment. When off (default), the classic light
    /// paper-white fill is used.
    @Published var isDarkModeChrome: Bool {
        didSet {
            UserDefaults.standard.set(isDarkModeChrome, forKey: Keys.darkModeChrome)
            Self.isDarkModeChromeShared = isDarkModeChrome
        }
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

    /// Per-app animation overrides: bundle ID → `BillState.rawValue`.
    /// The router consults this before the special-app mapper and category
    /// pools when an app is activated, so any app on this Mac can have its
    /// own signature reaction. Empty entry = automatic.
    @Published var perAppAnimations: [String: String] {
        didSet { UserDefaults.standard.set(perAppAnimations, forKey: Keys.perAppAnimations) }
    }

    @Published private(set) var launchAtLoginStatus: SMAppService.Status

    init() {
        let defaults = UserDefaults.standard
        isRoamingEnabled = (defaults.object(forKey: Keys.roaming) as? Bool) ?? true
        isMinimizeMischiefEnabled = (defaults.object(forKey: Keys.minimizeMischief) as? Bool) ?? true
        isWindowPushingEnabled = (defaults.object(forKey: Keys.windowPushing) as? Bool) ?? false
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
        perAppAnimations = defaults.dictionary(forKey: Keys.perAppAnimations) as? [String: String] ?? [:]
        isDarkModeChrome = (defaults.object(forKey: Keys.darkModeChrome) as? Bool) ?? false
        isAlwaysOnTop = (defaults.object(forKey: Keys.alwaysOnTop) as? Bool) ?? true
        activeCharacterID = defaults.string(forKey: Keys.activeCharacter) ?? "bill"
        activeCompanionIDs = defaults.stringArray(forKey: Keys.activeCompanions) ?? []
        customFamilyMap = defaults.dictionary(forKey: Keys.customFamilyMap) as? [String: String] ?? [:]
        familyFacingMap = defaults.dictionary(forKey: Keys.familyFacingMap) as? [String: String] ?? [:]
        worldModeMap = defaults.dictionary(forKey: Keys.worldModeMap) as? [String: String] ?? [:]
        familyWorldMap = defaults.dictionary(forKey: Keys.familyWorldMap) as? [String: String] ?? [:]
        mutedCompanionIDs = Set(defaults.stringArray(forKey: Keys.mutedCompanions) ?? [])
        disabledStateIDs = Set(defaults.stringArray(forKey: Keys.disabledStates) ?? [])
        isEnemySpawningEnabled = (defaults.object(forKey: Keys.enemySpawning) as? Bool) ?? false
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
