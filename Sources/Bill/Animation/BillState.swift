import Foundation

/// Every mood/behavior Bill can be in. The animation engine can render all of
/// these; `CharacterEngine` (and later the system monitor / chat bridge)
/// decide *when* to request them.
///
/// `confused`, `dazed`, `poked`, `smug` are ordinary personality beats added
/// during the first sprite-sheet pass. `powerSurge`, `zodiacVision`, and
/// `summonRitual` were the first rare Easter eggs. The second, annotation-
/// driven pass (see `Docs/SpriteAnimationCatalog.md`) added `caneFlourish`
/// (a lighter, more frequent personality flourish) and four more rare
/// Easter eggs — `ghostPale`, `glitchForm`, `shadowHands`, `meltdown` — all
/// backed by real, complete sequences from the annotated sheet rather than
/// discarded as "too strange for a companion."
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
    case caneFlourish
    case powerSurge
    case zodiacVision
    case summonRitual
    case ghostPale
    case glitchForm
    case shadowHands
    case meltdown

    /// Higher priority states can interrupt lower ones mid-beat.
    /// Reactive/emotional spikes outrank ambient/idle behavior. Rare
    /// Easter eggs sit deliberately high — once one rolls, it should play
    /// out rather than get immediately stomped by an ambient reaction.
    var priority: Int {
        switch self {
        case .surprised: return 100
        case .poked: return 95
        case .meltdown: return 99
        case .powerSurge: return 98
        case .glitchForm: return 97
        case .ghostPale: return 94
        case .zodiacVision: return 92
        case .shadowHands: return 91
        case .summonRitual: return 90
        case .celebrating: return 89
        case .caneFlourish: return 82
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
             .smug, .caneFlourish, .powerSurge, .zodiacVision, .summonRitual,
             .ghostPale, .glitchForm, .shadowHands, .meltdown:
            return false
        }
    }

    /// Rare, dramatic beats reserved for `CharacterEngine`'s low-probability
    /// idle roll rather than any normal reaction path.
    static let rareEasterEggs: [BillState] = [
        .powerSurge, .zodiacVision, .summonRitual, .ghostPale, .glitchForm, .shadowHands, .meltdown,
    ]
}
