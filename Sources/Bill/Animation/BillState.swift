import Foundation

/// Every mood/behavior Bill can be in. The animation engine can render all of
/// these; `CharacterEngine` (and later the system monitor / chat bridge)
/// decide *when* to request them.
///
/// `confused`, `dazed`, `poked`, `smug` are ordinary personality beats added
/// during the sprite-sheet pass — each has a clean, dedicated frame sequence
/// that didn't map to any of the original 13. `powerSurge`, `zodiacVision`,
/// and `summonRitual` are deliberately dramatic/strange sequences from the
/// sheet (a many-eyed energy surge, the zodiac-wheel prophecy vision, a
/// ritual summoning circle) that don't belong in ordinary use — they're
/// wired as rare, low-probability Easter eggs (see `CharacterEngine`'s idle
/// beat scheduling) rather than discarded. See `Docs/SpriteAnimationCatalog.md`.
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
    case confused
    case dazed
    case poked
    case smug
    case powerSurge
    case zodiacVision
    case summonRitual

    /// Higher priority states can interrupt lower ones mid-beat.
    /// Reactive/emotional spikes outrank ambient/idle behavior. The three
    /// rare Easter eggs sit deliberately high — once one rolls, it should
    /// play out rather than get immediately stomped by an ambient reaction.
    var priority: Int {
        switch self {
        case .powerSurge: return 98
        case .poked: return 95
        case .surprised: return 100
        case .zodiacVision: return 92
        case .summonRitual: return 91
        case .celebrating: return 90
        case .heatingUp: return 80
        case .dazed: return 72
        case .annoyed: return 70
        case .confused: return 65
        case .smug: return 62
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
        case .idle, .happy, .annoyed, .surprised, .celebrating, .confused, .dazed, .poked,
             .smug, .powerSurge, .zodiacVision, .summonRitual:
            return false
        }
    }

    /// Rare, dramatic beats reserved for `CharacterEngine`'s low-probability
    /// idle roll rather than any normal reaction path.
    static let rareEasterEggs: [BillState] = [.powerSurge, .zodiacVision, .summonRitual]
}
