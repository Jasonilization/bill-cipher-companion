import Foundation

/// The closed set of dialogue keys that are looked up by name rather than
/// composed at runtime.
///
/// `DialogueLibrary` is backed by JSON, so this enum is what keeps a typo from
/// silently turning into "Bill says nothing": every case here must exist in
/// `dialogue.json`, and `DialogueLibrary.missingKeys()` reports any that
/// doesn't. Keys that are *composed* — `battery.35`, `clock.2130`,
/// `transition.coding->music` — are deliberately not cases here; they are
/// built by the helpers at the bottom of this file and resolved through a
/// fallback ladder, so a missing one degrades to a generic line instead of
/// being a compile error for a combination nobody authored.
enum DialogueKey: String, CaseIterable, Codable, Sendable {
    case aiChat
    case ambushed
    case appLaunchDescribed
    case appLaunchFirstSighting
    case appLaunchGeneric
    case appLaunchStillUnknown
    case batteryCharging
    case batteryLow
    case browsing
    case browsingStore
    case caneTwist
    case charged
    case chatFailed
    case coding
    case communication
    case conjuring
    case cpuHot
    case creative
    case cultLeader
    case dancing
    case darkWorld
    case dashTarget
    case dispatching
    case dreading
    case finder
    case flinching
    case fractaling
    case gaming
    case gettingSleepy
    case ghostPale
    case glitchForm
    case glitching
    case grooving
    case grumpEyes
    case guilty
    case hollowed
    case hookCane
    case huffy
    case kinship
    case meltdown
    case music
    case networkLost
    case networkRestored
    case poked
    case powerSurge
    case presenting
    case productivity
    case pushingCode
    case rampaging
    case returningFavorite
    case ritualBuildup
    case roamFellOffWorld
    case roamHardLanding
    case roamLedgeGrab
    case scanning
    case sculpting
    case shadowHands
    case smug
    case sneaking
    case spooked
    case stillThinking
    case stressed
    case summonRitual
    case summoning
    case tinkering
    case transferring
    case zodiacRage
    case prismDance
    case zodiacCrimson
    case trickster
    case tumbling
    case userReturned
    case waking
    case watched
    case zipAround
    case zodiacVision
}

extension DialogueKey {
    /// Discharging battery, at a 5% step.
    static func battery(_ percent: Int) -> [String] {
        ["battery.\(percent)", "battery.step"]
    }

    /// Charging battery, at a 5% step.
    static func charge(_ percent: Int) -> [String] {
        percent >= 100 ? ["charge.full", "charge.step"] : ["charge.\(percent)", "charge.step"]
    }

    /// Output volume crossing one of the marks the user asked about.
    static func volume(_ percent: Int) -> [String] {
        ["volume.\(percent)"]
    }

    /// The half-hour chime: the exact half hour if it has its own line,
    /// otherwise a generic one for this part of the day.
    static func clock(hour: Int, minute: Int, timeOfDay: TimeOfDay) -> [String] {
        let stamp = String(format: "clock.%02d%02d", hour, minute)
        return [stamp, "clock.\(timeOfDay.rawValue)"]
    }

    /// Moving from one app to another. Falls back from the exact pair to a
    /// generic transition line.
    static func transition(from: String, to: String) -> [String] {
        ["transition.\(from)->\(to)", "transition.generic"]
    }

    /// Returning to an app that was already open. Goes silent after the third.
    static func refocus(count: Int) -> [String]? {
        guard (1...3).contains(count) else { return nil }
        return ["refocus.\(count)"]
    }

    /// A blocked app during Study Mode, escalating with each attempt.
    static func studyBlocked(offence: Int) -> [String] {
        ["study.blocked\(min(max(offence, 1), 3))"]
    }
}
