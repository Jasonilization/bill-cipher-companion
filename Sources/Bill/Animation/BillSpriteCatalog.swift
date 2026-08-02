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
    static let celebrating = loadFrames("bill_celebrating", count: 5)
    static let curious = loadFrames("bill_curious", count: 4)
    static let cane = loadFrames("bill_cane", count: 8)

    // Rare Easter eggs / special events.
    static let powerSurge = loadFrames("bill_powersurge", count: 4)
    static let powerSurgeClose = loadFrames("bill_powersurgeclose", count: 1)
    static let portalRing = loadFrames("bill_portalring", count: 8)
    static let zodiac = loadFrames("bill_zodiac", count: 8)
    static let summonBuild = loadFrames("bill_summonbuild", count: 3)
    static let summonHold = loadFrames("bill_summonhold", count: 1)
    static let ghost = loadFrames("bill_ghost", count: 5)
    static let glitch = loadFrames("bill_glitch", count: 4)
    static let shadowA = loadFrames("bill_shadowa", count: 5)
    static let shadowB = loadFrames("bill_shadowb", count: 4)
    static let meltdown = loadFrames("bill_meltdown", count: 8)

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
