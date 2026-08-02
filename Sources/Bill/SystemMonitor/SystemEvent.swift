import Foundation

enum AppCategory: String, Sendable, CaseIterable, Codable {
    case coding
    case gaming
    case browsing
    case music
    case creative
    case finder

    var displayName: String {
        switch self {
        case .coding: return "Coding"
        case .gaming: return "Gaming"
        case .browsing: return "Browsing"
        case .music: return "Music"
        case .creative: return "Creative apps"
        case .finder: return "Finder"
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
