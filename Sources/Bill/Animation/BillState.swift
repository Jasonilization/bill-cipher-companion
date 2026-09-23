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
    case channeling
    case focused
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

    // Dock-app reactions (animation-director audit — see
    // `Docs/SpriteAnimationCatalog.md`). Each backs one specific app or a
    // small cluster of genuinely-equivalent apps (see `SpecialAppMapper`).
    case trickster
    case darkWorld
    case hollowed
    case cultLeader
    case spooked
    case scanning
    case sneaking
    case glitching
    case charged
    case transferring
    case summoning
    case sculpting
    case kinship
    case fractaling
    case presenting
    case guilty
    case dreading
    case grooving
    case dispatching
    case ambushed
    case stressed
    case watched
    case flinching
    case huffy
    case pushingCode
    case browsingStore
    case dancing

    // More verified groups with no natural per-app fit — rare Easter eggs
    // (see `rareEasterEggs` below) rather than forced triggers.
    case caneTwist
    case hookCane
    case conjuring
    case tumbling
    case dashTarget
    case grumpEyes
    case zipAround
    case rampaging

    // Desktop-roaming physics beats (see `GravitySimulator`/`RoamingController`).
    // Every one of these is backed by real sprite art already exported from
    // the sheet — nothing here is a procedural placeholder:
    //   crouching/launching/landing*  → group 07 "duck flinch" (`bill_flinching`),
    //       a genuine three-frame squash: upright → compressed → flattened.
    //       Played forward it is an anticipation crouch; reversed it is the
    //       extension that launches him.
    //   falling                       → group 29 "dizzy tumble" (`bill_tumbling`),
    //       four frames of limbs flailing at different rotations — already
    //       airborne art, which is exactly what a fall needs.
    //   climbing*/hangingIdle/ledgeGrabbing → group 20 "sneak crouch cycle"
    //       (`bill_sneaking`), a low gripping pose whose legs read as holding on.
    //   running                       → group 42 "red rampage run" (`bill_rampaging`).
    //   edgePeek                      → group 31 "eye opening focus" (`bill_focused`).
    case crouching
    case launching
    case rising
    case falling
    case landingSoft
    case landingHard
    case ledgeGrabbing
    case climbingUp
    case climbingDown
    case hangingIdle
    case edgePeek
    case running

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
        case .focused: return 58
        case .gaming, .coding, .channeling: return 50
        case .trickster, .darkWorld, .hollowed, .cultLeader, .spooked, .scanning, .sneaking,
             .glitching, .charged, .transferring, .summoning, .sculpting, .kinship, .fractaling,
             .presenting, .guilty, .dreading, .grooving, .dispatching, .ambushed, .stressed,
             .watched, .flinching, .huffy, .pushingCode, .browsingStore, .dancing:
            return 50
        case .caneTwist, .hookCane, .conjuring, .tumbling, .dashTarget, .grumpEyes, .zipAround, .rampaging:
            return 85
        // Above every ambient/app reaction (50) but below emotional spikes:
        // once Bill is genuinely mid-air, the animation has to stay in sync
        // with where the simulation is actually putting him, so a passing
        // app-launch beat must not stomp a fall. Being poked or grabbed
        // still outranks it, which is correct — those *should* interrupt.
        case .crouching, .launching, .rising, .falling, .landingSoft, .landingHard,
             .ledgeGrabbing, .climbingUp, .climbingDown, .hangingIdle, .edgePeek, .running:
            return 55
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
        case .talking, .thinking, .sleeping, .gaming, .coding, .channeling, .heatingUp, .charging, .walking,
             .sneaking, .glitching, .pushingCode, .browsingStore,
             // Held for as long as the simulation says so — a fall lasts
             // exactly as long as the fall does, not a fixed clip length.
             .rising, .falling, .climbingUp, .climbingDown, .hangingIdle, .running:
            return true
        case .idle, .happy, .annoyed, .surprised, .celebrating, .confused, .dazed, .poked,
             .smug, .focused, .caneFlourish, .powerSurge, .zodiacVision, .summonRitual,
             .ghostPale, .glitchForm, .shadowHands, .meltdown,
             .trickster, .darkWorld, .hollowed, .cultLeader, .spooked, .scanning, .charged,
             .transferring, .summoning, .sculpting, .kinship, .fractaling, .presenting, .guilty,
             .dreading, .grooving, .dispatching, .ambushed, .stressed, .watched, .flinching,
             .huffy, .dancing,
             .caneTwist, .hookCane, .conjuring, .tumbling, .dashTarget, .grumpEyes, .zipAround, .rampaging,
             .crouching, .launching, .landingSoft, .landingHard, .ledgeGrabbing, .edgePeek:
            return false
        }
    }

    /// How long a continuous state may hold before settling back to idle by
    /// itself. `nil` means "hold until something explicitly ends it".
    ///
    /// This exists because continuous states were latching permanently. A
    /// single app activation could put Bill into `.glitching` (or `.coding`,
    /// `.sneaking`, `.browsingStore`…), and nothing ever requested `.idle`
    /// afterwards — there is no "app deactivated" event. While latched,
    /// *everything* gated on `currentState == .idle` stopped: roaming, idle
    /// beats, rare Easter eggs and the daily coverage sweep. Observed live in
    /// the roaming trace as `BAIL state=glitching` repeating forever, and it
    /// is the main reason wandering looked absent.
    ///
    /// These are *reactions*, not conditions — the point is made after a few
    /// seconds. The genuine conditions (asleep, charging, hot) keep `nil`
    /// because they have real events that end them.
    var maxHoldDuration: TimeInterval? {
        guard isContinuous else { return nil }
        switch self {
        // Genuinely asleep: a sleeping pet should not wander off, and
        // `.userReturned` reliably wakes him.
        case .sleeping: return nil
        // These two *are* machine conditions, but their exit events can be a
        // very long time coming — the CPU stays above the hot threshold for as
        // long as a game is running, and a plugged-in laptop stays plugged in
        // all evening. Holding the state that whole time froze Bill in place:
        // observed live as `BAIL state=heatingUp` repeating for as long as a
        // game was open, with no roaming at all. The steam/spark FX has already
        // made the point after a few seconds; the condition does not need to
        // own his body indefinitely.
        case .heatingUp: return 12
        case .charging: return 10
        // Driven frame-by-frame by the simulation / chat, which owns the exit.
        case .walking, .running, .rising, .falling,
             .climbingUp, .climbingDown, .hangingIdle,
             .talking, .thinking: return nil
        // Everything else is an app reaction.
        default: return 9
        }
    }

    /// True for the states the roaming simulation drives directly. The
    /// roaming controller owns Bill's animation completely while one of
    /// these is current, so ambient behaviour (idle beats, rare Easter eggs,
    /// cursor reactions) must stand down rather than fight it.
    var isRoamingMotion: Bool {
        switch self {
        case .crouching, .launching, .rising, .falling, .landingSoft, .landingHard,
             .ledgeGrabbing, .climbingUp, .climbingDown, .hangingIdle, .edgePeek,
             .running, .walking:
            return true
        default:
            return false
        }
    }

    /// Rare, dramatic beats reserved for `CharacterEngine`'s low-probability
    /// idle roll rather than any normal reaction path.
    static let rareEasterEggs: [BillState] = [
        .powerSurge, .zodiacVision, .summonRitual, .ghostPale, .glitchForm, .shadowHands, .meltdown,
        .caneTwist, .hookCane, .conjuring, .tumbling, .dashTarget, .grumpEyes, .zipAround, .rampaging,
    ]
}
