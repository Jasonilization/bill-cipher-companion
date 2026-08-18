import SpriteKit
import AppKit

/// Loads Bill's pixel-art frames (see `Docs/SpriteAnimationCatalog.md` for
/// the full analysis of the source sheet) into `SKTexture`s once, with
/// nearest-neighbor filtering so the pixel art stays crisp at any scale —
/// no smoothing, no anti-aliasing, no blur.
///
/// Every frame across every group was re-exported onto one shared,
/// bottom-center-aligned canvas (118×111 — see the extraction methodology in
/// the analysis doc). That's what stops Bill from visibly snapping/clipping
/// when a state swaps textures: every texture has identical pixel
/// dimensions and the same "feet" reference row, whether it's a tight
/// 39×58 idle crop or a 117×102 shadow-claw frame.
@MainActor
enum BillSpriteCatalog {
    static let idle = loadFrames("bill_idle", count: 7)
    static let walk = loadFrames("bill_walk", count: 6)
    static let annoyed = loadFrames("bill_annoyed", count: 6)
    static let happy = loadFrames("bill_happy", count: 2)
    static let confused = loadFrames("bill_confused", count: 4)
    static let heating = loadFrames("bill_heating", count: 7)
    static let charging = loadFrames("bill_charging", count: 1)
    static let surprised = loadFrames("bill_surprised", count: 3)
    static let poked = loadFrames("bill_poked", count: 4)
    static let dazed = loadFrames("bill_dazed", count: 2)
    static let sleeping = loadFrames("bill_sleeping", count: 1)
    static let thinking = loadFrames("bill_thinking", count: 4)
    static let coding = loadFrames("bill_coding", count: 2)
    static let talking = loadFrames("bill_talking", count: 3)
    static let smug = loadFrames("bill_smug", count: 2)
    static let snap = loadFrames("bill_snap", count: 3)
    static let focused = loadFrames("bill_focused", count: 4)
    static let channeling = loadFrames("bill_channeling", count: 9)
    static let celebrating = loadFrames("bill_celebrating", count: 5)
    static let curious = loadFrames("bill_curious", count: 4)
    static let cane = loadFrames("bill_cane", count: 8)

    // Rare Easter eggs / special events.
    static let powerSurge = loadFrames("bill_powersurge", count: 4)
    static let powerSurgeClose = loadFrames("bill_powersurgeclose", count: 1)
    static let portalRing = loadFrames("bill_portalring", count: 8)
    static let zodiac = loadFrames("bill_zodiac", count: 8)
    /// Replaces the old `summonBuild`(3)+`summonHold`(1) pair — the
    /// animation-director audit found the sheet's actual "glowing ritual
    /// circle" (8 identical clone-triangles arranged in a ring, matching the
    /// classic Bill-Cipher summoning motif) elsewhere on the sheet, a
    /// stronger match for `summonRitual`'s own name/doc-comment than the
    /// growth sequence previously backing it. Frame 1 is the full static
    /// ring (curated as one merged frame, not an animatable sequence in its
    /// own right); frames 2-4 are alternate eye-render variants of Bill
    /// standing in it.
    static let summonRitual = loadFrames("bill_summonritual", count: 4)
    /// Re-exported through the corrected pipeline — was 5 frames (the pale
    /// materialize-in only); the sheet's white box actually continues for 3
    /// more frames (solid yellow true-form, a mark across the body, settling
    /// in a red pool) with no internal border separating them from the first
    /// 5, so the full 8-frame sequence is one continuous beat, not two.
    static let ghost = loadFrames("bill_ghost", count: 8)
    static let glitch = loadFrames("bill_glitch", count: 4)
    static let shadowA = loadFrames("bill_shadowa", count: 5)
    static let shadowB = loadFrames("bill_shadowb", count: 4)
    static let meltdown = loadFrames("bill_meltdown", count: 8)

    // MARK: - Dock-app reactions (animation-director audit — see
    // `Docs/SpriteAnimationCatalog.md`). Each of these backs one specific
    // app or a small cluster of genuinely-equivalent apps (see
    // `SpecialAppMapper`), rather than one of the broad `AppCategory`
    // buckets above — the sheet had enough distinct, verified material to
    // give the dock's more distinctive apps their own reaction instead of
    // lumping everything into `coding`/`creative`.
    static let trickster = loadFrames("bill_trickster", count: 8)
    static let darkWorld = loadFrames("bill_darkworld", count: 9)
    static let hollowed = loadFrames("bill_hollowed", count: 11)
    static let cultLeader = loadFrames("bill_cultleader", count: 8)
    static let spooked = loadFrames("bill_spooked", count: 5)
    static let scanning = loadFrames("bill_scanning", count: 8)
    static let sneaking = loadFrames("bill_sneaking", count: 6)
    static let glitching = loadFrames("bill_glitching", count: 4)
    static let charged = loadFrames("bill_charged", count: 6)
    static let transferring = loadFrames("bill_transferring", count: 12)
    static let summoning = loadFrames("bill_summoning", count: 8)
    static let sculpting = loadFrames("bill_sculpting", count: 14)
    static let kinship = loadFrames("bill_kinship", count: 5)
    static let fractaling = loadFrames("bill_fractaling", count: 3)
    static let presenting = loadFrames("bill_presenting", count: 3)
    static let guilty = loadFrames("bill_guilty", count: 3)
    static let dreading = loadFrames("bill_dreading", count: 4)
    static let grooving = loadFrames("bill_grooving", count: 3)
    static let dispatching = loadFrames("bill_dispatching", count: 4)
    static let ambushed = loadFrames("bill_ambushed", count: 8)
    static let stressed = loadFrames("bill_stressed", count: 7)
    static let watched = loadFrames("bill_watched", count: 5)
    static let flinching = loadFrames("bill_flinching", count: 3)
    static let huffy = loadFrames("bill_huffy", count: 6)
    static let pushingCode = loadFrames("bill_pushingcode", count: 6)
    static let browsingStore = loadFrames("bill_browsingstore", count: 3)
    static let dancing = loadFrames("bill_dancing", count: 7)

    // Remaining verified groups with no natural app pairing — folded into
    // the rare-event rotation (see `BillState.rareEasterEggs`) instead of a
    // forced trigger, per "not every animation needs to be common."
    static let caneTwist = loadFrames("bill_canetwist", count: 8)
    static let hookCane = loadFrames("bill_hookcane", count: 5)
    static let conjuring = loadFrames("bill_conjuring", count: 18)
    static let tumbling = loadFrames("bill_tumbling", count: 4)
    static let dashTarget = loadFrames("bill_dashtarget", count: 4)
    static let grumpEyes = loadFrames("bill_grumpeyes", count: 6)
    static let zipAround = loadFrames("bill_ziparound", count: 11)
    static let rampaging = loadFrames("bill_rampaging", count: 10)

    /// The single frame everything else falls back to / settles on.
    static var restTexture: SKTexture { idle[0] }

    private static func loadFrames(_ prefix: String, count: Int) -> [SKTexture] {
        (1...count).compactMap { i -> SKTexture? in
            let name = String(format: "%@_%02d", prefix, i)
            guard
                let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Sprites"),
                let image = NSImage(contentsOf: url)
            else {
                print("BillSpriteCatalog: missing sprite frame \(name)")
                return nil
            }
            let texture = SKTexture(image: image)
            texture.filteringMode = .nearest
            return texture
        }
    }
}
