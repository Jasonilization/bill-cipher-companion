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
    case appActivated(bundleID: String, name: String, category: AppCategory?)
    case batteryLow(percentage: Int)
    case batteryCharging
    case batteryUnplugged
    case networkLost
    case networkRestored
    case cpuHot
    case cpuNormal
    case userIdle
    case userReturned
}
