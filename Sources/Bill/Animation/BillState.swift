import Foundation

/// Every mood/behavior Bill can be in. The animation engine can render all of
/// these; `CharacterEngine` (and later the system monitor / chat bridge)
/// decide *when* to request them.
enum BillState: String, CaseIterable, Sendable {
    case idle
    case walking
    case talking
    case thinking
    case happy
    case annoyed
    case sleeping
    case gaming
    case coding
    case heatingUp
    case charging
    case surprised
    case celebrating

    /// Higher priority states can interrupt lower ones mid-beat.
    /// Reactive/emotional spikes outrank ambient/idle behavior.
    var priority: Int {
        switch self {
        case .surprised: return 100
        case .celebrating: return 90
        case .heatingUp: return 80
        case .annoyed: return 70
        case .happy: return 60
        case .gaming, .coding: return 50
        case .thinking, .talking: return 45
        case .charging: return 40
        case .walking: return 30
        case .sleeping: return 20
        case .idle: return 0
        }
    }

    /// Whether this state loops continuously while active (true) or plays a
    /// single beat and then settles back to idle (false).
    var isContinuous: Bool {
        switch self {
        case .talking, .thinking, .sleeping, .gaming, .coding, .heatingUp, .charging, .walking:
            return true
        case .idle, .happy, .annoyed, .surprised, .celebrating:
            return false
        }
    }
}
