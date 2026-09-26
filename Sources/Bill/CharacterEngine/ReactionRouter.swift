import AppKit
import Foundation

/// Maps normalized `SystemEvent`s to what Bill actually does: a state, a bark,
/// and sometimes a trip across the desktop to the window in question.
///
/// This is the only place system events and character behaviour meet —
/// `SystemMonitor` stays dumb, `CharacterEngine`/`BillStateMachine` stay
/// unaware of *why* a state was requested.
///
/// Two rules hold across every path here, both requested explicitly:
///
/// - **Animations never repeat back-to-back.** Every reaction picks its state
///   through `AnimationCoverage.pick(from:)` from a *pool* of plausible
///   animations rather than hard-coding one, so the same trigger looks
///   different each time and the library gets daily coverage as a side effect.
/// - **Bill only speaks about things that actually happened.** Every line
///   below is attached to a real event, and every one is looked up through
///   `DialogueLibrary`, which selects a time-of-day-appropriate variant.
@MainActor
final class ReactionRouter {
    private let characterEngine: CharacterEngine
    private let preferences: AppPreferences
    private let memoryStore: MemoryStore
    private var dialogue: DialogueLibrary { .shared }
    private let screenReader = ScreenTextReader()

    /// Sends Bill to physically stand on an app's window. Wired by
    /// `AppDelegate` to `CharacterWindowController.sendBillToApp`.
    var goToApp: ((pid_t) -> Bool)?
    /// Consulted before any app reaction — Study Mode gets first refusal so it
    /// can block instead of react. Returns `true` if it handled the activation.
    /// Decides whether Bill should point out that no homework / learning /
    /// fun has happened today. Driven by the half-hour chime.
    var habitNagger: HabitNagger?
    var studyModeInterceptor: ((_ bundleID: String, _ name: String, _ pid: pid_t) -> Bool)?

    // MARK: - Per-session app focus state
    //
    // Deliberately in-memory rather than in `MemoryStore`: "first time this
    // session" and "how many times have you come back" are session concepts,
    // and persisting them would mean a relaunch silently owed you three
    // refocus lines from yesterday.

    /// Bundle IDs that have been activated at least once this session.
    private var seenThisSession: Set<String> = []
    /// How many times each app has been *returned* to this session.
    private var refocusCount: [String: Int] = [:]
    /// The tag (special state or category) of the app we came from, for
    /// FROM->TO transition lines.
    private var previousFocusTag: String?
    private var previousBundleID: String?
    /// Guards against the double-activation macOS sometimes emits for a single
    /// user-visible switch, and against a rapid alt-tab bounce being counted
    /// as a genuine return.
    private var lastActivationAt: [String: Date] = [:]
    private static let bounceWindow: TimeInterval = 4

    /// After this many returns to the same app, Bill stops commenting on it
    /// for the rest of the session.
    private static let maxRefocusLines = 3

    // MARK: - Animation pools
    //
    // Each is a set of states that all read correctly for that event. The
    // coverage tracker chooses between them, so a pool of six means six
    // different-looking reactions to the same event and six animations
    // getting screen time.

    private static let batteryDrainingStates: [BillState] = [
        .stressed, .dreading, .huffy, .grumpEyes, .watched, .annoyed, .confused,
    ]
    private static let batteryChargingStates: [BillState] = [
        // `.charging` is the dedicated plugged-in pose and must stay in this
        // pool — it is the one state whose *only* real-world trigger is this
        // event, and the coverage sweep deliberately never showcases it
        // (standing in a charging pose while unplugged reads as a bug).
        .charging, .charged, .celebrating, .happy, .powerSurge, .transferring,
    ]
    private static let volumeStates: [BillState] = [
        .dancing, .grooving, .happy, .flinching, .surprised, .caneFlourish, .kinship,
    ]
    private static let networkDownStates: [BillState] = [
        .confused, .glitchForm, .spooked, .dazed, .glitching, .ambushed,
    ]
    private static let networkUpStates: [BillState] = [
        .celebrating, .happy, .charged, .zipAround, .fractaling,
    ]
    private static let clockStates: [BillState] = [
        .presenting, .dispatching, .watched, .smug, .zodiacVision, .caneTwist,
        .hookCane, .focused, .scanning, .conjuring,
    ]
    private static let insightStates: [BillState] = [
        .watched, .scanning, .presenting, .dreading, .guilty, .smug, .focused,
    ]
    private static let nagStates: [BillState] = [
        .dreading, .guilty, .grumpEyes, .annoyed, .huffy, .stressed, .cultLeader,
    ]

    init(characterEngine: CharacterEngine, preferences: AppPreferences, memoryStore: MemoryStore) {
        self.characterEngine = characterEngine
        self.preferences = preferences
        self.memoryStore = memoryStore
    }

    // MARK: - Entry point

    func handle(_ event: SystemEvent) {
        switch event {
        case .appActivated(let bundleID, let name, let category, let pid):
            memoryStore.recordAppOpen(bundleID: bundleID, name: name, category: category)
            handleAppActivated(bundleID: bundleID, name: name, category: category, pid: pid)

        case .batteryLow:
            memoryStore.recordLowBatteryEvent()
            play(Self.batteryDrainingStates, keys: ["batteryLow"], importance: .always)

        case .batteryLevel(let percent, let isCharging):
            handleBatteryLevel(percent: percent, isCharging: isCharging)

        case .batteryCharging:
            memoryStore.recordChargingEvent()
            play(Self.batteryChargingStates, keys: ["batteryCharging"])

        case .batteryUnplugged:
            characterEngine.request(.idle)

        case .networkLost:
            play(Self.networkDownStates, keys: ["networkLost"], importance: .always)

        case .networkRestored:
            play(Self.networkUpStates, keys: ["networkRestored"])

        case .networkQualityChanged(let quality):
            handleNetworkQuality(quality)

        case .cpuHot:
            characterEngine.request(.heatingUp)
            speak(["cpuHot"])

        case .cpuNormal:
            characterEngine.request(.idle)

        case .userIdle:
            idleStartDate = Date()
            speak(["gettingSleepy"])
            characterEngine.request(.sleeping)

        case .userReturned:
            handleUserReturned()

        case .volumeMark(let percent):
            play(Self.volumeStates, keys: DialogueKey.volume(percent))

        case .volumeMuteChanged(let isMuted):
            play(Self.volumeStates, keys: [isMuted ? "volume.mute" : "volume.unmute"])

        case .halfHour(let hour, let minute):
            handleHalfHour(hour: hour, minute: minute)
            // Piggy-backed on the chime rather than given its own timer.
            habitNagger?.considerNagging()

        case .timeOfDayChanged:
            // The dialogue pools swap themselves via `TimeOfDayCache`; nothing
            // to announce here beyond what the half-hour chime already says.
            break

        case .weatherChanged(let snapshot, let reason):
            handleWeatherReport(snapshot, reason: reason)
        }
    }

    // MARK: - Weather

    /// Cooldown applies only to the quiet, non-urgent report paths; a
    /// first-pull or an explicit user test always speaks.
    private var lastWeatherBarkAt: Date?

    private func handleWeatherReport(_ snapshot: WeatherSnapshot, reason: WeatherMonitor.ReportReason) {
        let loud = reason == .firstPull || reason == .forcedTest
        if !loud,
           let lastWeatherBarkAt, Date().timeIntervalSince(lastWeatherBarkAt) < Self.weatherBarkCooldown {
            return
        }
        lastWeatherBarkAt = Date()
        let temp = String(format: "%.0f", snapshot.temperatureC.rounded())
        play(
            Self.weatherStates,
            keys: ["weather.\(snapshot.condition.rawValue)"],
            substitutions: ["temp": temp],
            importance: loud ? .always : .normal
        )
    }

    private static let weatherBarkCooldown: TimeInterval = 10 * 60
    private static let weatherStates: [BillState] = [
        .watched, .scanning, .smug, .caneTwist, .presenting, .zodiacVision, .conjuring,
    ]

    private var idleStartDate: Date?

    // MARK: - App activation

    private func handleAppActivated(bundleID: String, name: String, category: AppCategory?, pid: pid_t) {
        // Study Mode gets first refusal: a blocked app is confronted, not
        // commented on.
        if studyModeInterceptor?(bundleID, name, pid) == true { return }

        // Collapse the duplicate activation macOS emits for a single switch.
        if let last = lastActivationAt[bundleID], Date().timeIntervalSince(last) < Self.bounceWindow {
            lastActivationAt[bundleID] = Date()
            return
        }
        lastActivationAt[bundleID] = Date()

        let tag = focusTag(bundleID: bundleID, name: name, category: category)

        if seenThisSession.contains(bundleID) {
            handleRefocus(bundleID: bundleID, name: name, tag: tag, pid: pid)
        } else {
            seenThisSession.insert(bundleID)
            handleFirstOpen(bundleID: bundleID, name: name, category: category, tag: tag, pid: pid)
        }

        previousFocusTag = tag
        previousBundleID = bundleID
        observeWindowTitle(pid: pid, appName: name)
    }

    /// Looks at *what* you have open, not just which app.
    ///
    /// Fire-and-forget and fully optional: if Accessibility has not been
    /// granted, or the app doesn't publish a title, or the read times out
    /// because the app is hung, this produces nothing and the reaction Bill
    /// already gave stands on its own. It never blocks the activation path.
    private func observeWindowTitle(pid: pid_t, appName: String) {
        guard preferences.isWindowAwarenessEnabled, WindowTitleReader.isTrusted else { return }
        Task { [weak self] in
            guard let title = await WindowTitleReader.focusedWindowTitle(pid: pid) else { return }
            guard let self else { return }
            var resolved = WindowTitleInsight.insight(appName: appName, title: title)
            // The title got us the section; OCR gets us the numbers — "you
            // have 3 missing" is not something a window title ever says. Only
            // attempted when explicitly enabled, for a handful of apps, on a
            // 20-minute per-app cooldown.
            if self.preferences.isScreenOCREnabled,
               let text = await self.screenReader.readFocusedWindow(pid: pid, appName: appName),
               let deeper = ScreenTextInsight.insight(appName: appName, text: text) {
                resolved = deeper
            }
            guard let insight = resolved else { return }
            // Behind the app's own line, so the order reads as
            // "oh, Classroom" then "...the to-do list, specifically".
            var subs = insight.substitutions
            subs["app"] = appName
            self.play(Self.insightStates, keys: [insight.key], substitutions: subs)
        }
    }

    /// The first time an app is activated in a session it always reacts, with
    /// **no cooldown of any kind**.
    ///
    /// The previous implementation gated every app behind a 5-minute
    /// per-category cooldown and an 8-minute generic one, which meant opening
    /// Slides and then Gmail immediately produced exactly one reaction — the
    /// second was silently swallowed because it shared a bucket or landed
    /// inside the window. Both now speak. The bark *queue* (see
    /// `BillStateMachine.showBark`) is what makes that actually work: the two
    /// lines are spoken in sequence instead of the second destroying the first.
    private func handleFirstOpen(
        bundleID: String, name: String, category: AppCategory?, tag: String, pid: pid_t
    ) {
        guard category == nil || preferences.isCategoryEnabled(category!) else { return }

        // A transition line first, when we came from somewhere interesting.
        // Ladder: this user's own app *pair*, then the authored
        // tag-pair/category/generic ladder.
        if let from = previousFocusTag, from != tag {
            if let fromBundle = previousBundleID,
               let pairLine = dialogue.firstLine(
                [PersonalizedDialogueStore.shared.transitionKey(from: fromBundle, to: bundleID)],
                substitutions: ["app": name]
               ) {
                characterEngine.bark(pairLine)
            } else if let line = dialogue.firstLine(
                DialogueKey.transition(from: from, to: tag),
                substitutions: ["app": name]
            ) {
                characterEngine.bark(line)
            }
        }

        // Then the app's own reaction. Ladder: the user's explicit per-app
        // assignment (Settings → Per-app animations) first, then the
        // personalized line for this exact app, then the special-state and
        // category buckets.
        if let assigned = preferences.perAppAnimations[bundleID],
           let state = BillState(rawValue: assigned) {
            _ = goToApp?(pid)
            characterEngine.request(state, force: true)
            if let special = SpecialAppMapper.state(bundleID: bundleID, name: name) {
                speak([PersonalizedDialogueStore.shared.appKey(for: bundleID), special.rawValue], substitutions: ["app": name])
            } else {
                speak(["appLaunchGeneric"], substitutions: ["app": name])
            }
            return
        }
        if let special = SpecialAppMapper.state(bundleID: bundleID, name: name) {
            _ = goToApp?(pid)
            characterEngine.request(special, force: true)
            speak([PersonalizedDialogueStore.shared.appKey(for: bundleID), special.rawValue], substitutions: ["app": name])
            return
        }

        guard let category else {
            handleUncategorizedApp(bundleID: bundleID, name: name)
            return
        }

        let (states, key) = Self.reaction(for: category)
        play(states, keys: [PersonalizedDialogueStore.shared.appKey(for: bundleID), key], substitutions: ["app": name])
    }

    /// Returning to an already-seen app gets a distinct "back again?" line,
    /// three times, then silence for the rest of the session.
    private func handleRefocus(bundleID: String, name: String, tag: String, pid: pid_t) {
        let count = (refocusCount[bundleID] ?? 0) + 1
        refocusCount[bundleID] = count
        guard count <= Self.maxRefocusLines, let keys = DialogueKey.refocus(count: count) else { return }
        // Escalating animations: mildly amused, then pointed, then done with it.
        let states: [BillState] = count == 1 ? [.watched, .smug, .presenting]
                                 : count == 2 ? [.grumpEyes, .huffy, .annoyed]
                                              : [.dreading, .guilty, .stressed]
        play(states, keys: keys, substitutions: ["app": name])
    }

    /// Which broad reaction a category gets when no per-app override applies.
    /// Each returns a *pool*, so even the generic categories vary.
    private static func reaction(for category: AppCategory) -> ([BillState], String) {
        switch category {
        case .coding:        return ([.coding, .pushingCode, .focused, .thinking], "coding")
        case .gaming:        return ([.gaming, .browsingStore, .celebrating, .trickster], "gaming")
        case .creative:      return ([.sculpting, .kinship, .presenting, .conjuring], "creative")
        case .music:         return ([.dancing, .grooving, .happy], "music")
        case .browsing:      return ([.scanning, .watched, .confused], "browsing")
        case .finder:        return ([.scanning, .confused, .focused], "finder")
        case .communication: return ([.talking, .dispatching, .kinship], "communication")
        case .productivity:  return ([.focused, .presenting, .dreading, .sculpting], "productivity")
        case .aiChat:        return ([.smug, .glitching, .watched], "aiChat")
        case .tinkering:     return ([.channeling, .summoning, .scanning, .transferring], "tinkering")
        }
    }

    /// A stable label for an app, used as the FROM/TO key in transition
    /// lookups. Prefers the specific per-app state so "code -> Apple Music"
    /// can be authored distinctly from "code -> some other music app".
    private func focusTag(bundleID: String, name: String, category: AppCategory?) -> String {
        if let special = SpecialAppMapper.state(bundleID: bundleID, name: name) {
            return special.rawValue
        }
        return category?.rawValue ?? "other"
    }

    // MARK: - Battery / network / clock

    private func handleBatteryLevel(percent: Int, isCharging: Bool) {
        let keys = isCharging ? DialogueKey.charge(percent) : DialogueKey.battery(percent)
        let states = isCharging ? Self.batteryChargingStates : Self.batteryDrainingStates
        // Low battery matters enough to say regardless of how quiet Bill is
        // set to be; the rest is ordinary commentary.
        let importance: CharacterEngine.BarkImportance = (!isCharging && percent <= 20) ? .always : .normal
        play(states, keys: keys, substitutions: ["pct": String(percent)], importance: importance)
    }

    private func handleNetworkQuality(_ quality: NetworkQuality) {
        switch quality {
        case .poor:
            play(Self.networkDownStates, keys: ["network.slow"], importance: .always)
        case .excellent, .good:
            play(Self.networkUpStates, keys: ["network.fast"])
        case .offline:
            // `.networkLost` already covers this; don't say it twice.
            break
        }
    }

    private func handleHalfHour(hour: Int, minute: Int) {
        let keys = DialogueKey.clock(hour: hour, minute: minute, timeOfDay: TimeOfDayCache.current)
        // The user asked to be told the time every half hour, so this is not
        // subject to the speaking-frequency gate.
        play(Self.clockStates, keys: keys, importance: .always)
    }

    private func handleUserReturned() {
        if let idleStartDate {
            memoryStore.recordIdleDuration(Date().timeIntervalSince(idleStartDate))
        }
        idleStartDate = nil
        let wasAsleep = characterEngine.stateMachine.currentState == .sleeping
        characterEngine.request(.idle)
        speak([wasAsleep ? "waking" : "userReturned"])
    }

    /// An observation about what is on screen, from `AwarenessMonitor`.
    func reportInsight(_ insight: WindowTitleInsight.Insight) {
        var subs = insight.substitutions
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName { subs["app"] = app }
        play(Self.insightStates, keys: [insight.key], substitutions: subs)
    }

    /// Study Mode's announcements. Always spoken — the user turned this on
    /// deliberately and being told what it is doing is the whole point, so it
    /// is not subject to the speaking-frequency gate.
    func announceStudy(keys: [String], states: [BillState], substitutions: [String: String]) {
        play(states, keys: keys, substitutions: substitutions, importance: .always)
    }

    /// "You haven't done any homework / learning / anything fun today."
    /// Called by `HabitNagger`, which owns the timing and the anti-spam rules.
    func nag(_ key: String) {
        play(Self.nagStates, keys: [key], importance: .always)
    }

    // MARK: - Uncategorized apps

    private static let uncategorizedFrequentThreshold = 3

    private func handleUncategorizedApp(bundleID: String, name: String) {
        if let description = memoryStore.description(for: bundleID) {
            speak(["appLaunchDescribed"], substitutions: ["app": name, "description": description])
            if memoryStore.openCount(for: bundleID) >= Self.uncategorizedFrequentThreshold {
                characterEngine.request(.smug, force: true)
            }
            return
        }
        if memoryStore.isFirstSighting(of: bundleID) {
            characterEngine.stateMachine.playIdleVariant(.curious)
            speak(["appLaunchFirstSighting"], substitutions: ["app": name])
            return
        }
        if memoryStore.openCount(for: bundleID) >= Self.uncategorizedFrequentThreshold {
            play([.smug, .watched, .grumpEyes], keys: ["appLaunchStillUnknown"], substitutions: ["app": name])
            return
        }
        speak(["appLaunchGeneric"], substitutions: ["app": name])
    }

    // MARK: - Helpers

    /// Requests one of `states` (never the one that just played) and speaks the
    /// first authored line among `keys`.
    ///
    /// A per-trigger override from Settings (`customAnimationMap`) wins over
    /// the pool entirely: the user pinning "batteryLow" to `meltdown` means
    /// exactly that, every time.
    private func play(
        _ states: [BillState],
        keys: [String],
        substitutions: [String: String] = [:],
        importance: CharacterEngine.BarkImportance = .normal
    ) {
        let override: BillState? = keys
            .lazy
            .compactMap { self.preferences.customAnimationMap[$0] }
            .compactMap(BillState.init(rawValue:))
            .first
        if let override {
            characterEngine.request(override, force: true)
        } else if let state = characterEngine.coverage.pick(from: states) {
            characterEngine.request(state, force: true)
        }
        speak(keys, substitutions: substitutions, importance: importance)
    }

    private func speak(
        _ keys: [String],
        substitutions: [String: String] = [:],
        importance: CharacterEngine.BarkImportance = .normal
    ) {
        guard let line = dialogue.firstLine(keys, substitutions: substitutions) else { return }
        characterEngine.bark(line, importance: importance)
    }
}
