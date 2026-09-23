import Foundation

enum AppCategory: String, Sendable, CaseIterable, Codable {
    case coding
    case gaming
    case browsing
    case music
    case creative
    case finder
    /// Mail/chat/video-call apps — a distinct pose from `coding`'s "watching
    /// intently" read, since Bill's actually addressing someone here.
    case communication
    /// Docs/sheets/slides/notes/school-portal/language-learning apps — the
    /// "sits down and focuses" beat, distinct from `coding`'s pose.
    case productivity
    /// Another AI chat app specifically (there's more than one of these
    /// pinned in the dock) — a knowing, faintly territorial reaction rather
    /// than a neutral one.
    case aiChat
    /// Packet sniffers, SDR/radio tools, VM managers, flashing/imaging
    /// utilities — reads as "mad-science tinkering," which fits Bill's
    /// personality better than lumping it into plain `coding`.
    case tinkering

    var displayName: String {
        switch self {
        case .coding: return "Coding"
        case .gaming: return "Gaming"
        case .browsing: return "Browsing"
        case .music: return "Music"
        case .creative: return "Creative apps"
        case .finder: return "Finder"
        case .communication: return "Communication"
        case .productivity: return "Productivity"
        case .aiChat: return "AI chat"
        case .tinkering: return "Tinkering"
        }
    }
}

/// Normalized signals from the macOS event monitor. The monitor itself has
/// no behavior/personality logic — it just reports what happened; the
/// `ReactionRouter` decides what, if anything, Bill should do about it.
enum SystemEvent: Sendable {
    /// `pid` is carried so Bill can physically walk/jump to that app's
    /// frontmost window before reacting to it (and so Study Mode can hide it).
    case appActivated(bundleID: String, name: String, category: AppCategory?, pid: pid_t)
    case batteryLow(percentage: Int)
    /// Crossed a 5% step. Separate from `batteryLow`, which is the one-shot
    /// "you are in trouble" alarm — this is the running commentary the user
    /// asked for, and it fires in both directions.
    case batteryLevel(percent: Int, isCharging: Bool)
    case batteryCharging
    case batteryUnplugged
    case networkLost
    case networkRestored
    /// Link quality crossed a tier boundary (with hysteresis and a dwell
    /// time, so a flapping connection cannot spam this).
    case networkQualityChanged(NetworkQuality)
    case cpuHot
    case cpuNormal
    case userIdle
    case userReturned
    /// Output volume crossed one of the 0/25/50/75/100 marks.
    case volumeMark(percent: Int)
    case volumeMuteChanged(isMuted: Bool)
    /// A wall-clock half hour just passed.
    case halfHour(hour: Int, minute: Int)
    case timeOfDayChanged(TimeOfDay)
    /// A successful weather pull whose condition differs from the last one
    /// announced (see `WeatherMonitor.onConditionChanged` — a temperature
    /// drift within the same condition is deliberately not an event).
    case weatherChanged(WeatherSnapshot)
}

/// Coarse link quality. Deliberately four wide tiers rather than a number:
/// the user asked to be told when the connection "falls to very low" and when
/// it "returns high", which is a tier transition, and a raw RSSI readout would
/// flap constantly without telling them anything they can act on.
enum NetworkQuality: String, Sendable, Equatable {
    case offline
    case poor
    case good
    case excellent

    var isUsable: Bool { self != .offline }
}
