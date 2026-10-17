import Foundation
import CoreGraphics

/// One playable character, built from the shared-canvas sprite families in
/// `Resources/Packs/<pack>/Sprites/<prefix>_<family>_<NN>.png`.
///
/// Every character maps onto the SAME `BillState` space — that is the whole
/// design: the state machine, the reaction router, roaming physics, weather,
/// the chat bridge and the bark system all keep working untouched, whatever
/// is on screen. A pack only supplies three things: which texture family
/// each state plays (see `CharacterAnimationLibrary`), what size the frames
/// share (`canvasSize`, the anti-snap convention from `BillSpriteCatalog`),
/// and which dialogue file feeds its voice.
struct CharacterDefinition: Identifiable, Sendable, Hashable {
    let id: String
    let displayName: String
    let packID: String
    let packName: String
    /// File-name prefix of the sprite families. `"bill"` routes to the
    /// legacy `BillSpriteCatalog` (380 pre-processed frames) instead.
    let spritePrefix: String
    /// The one canvas size every frame of this character shares.
    let canvasSize: CGSize
    /// Canvas points → screen points. Tuned per character so their on-screen
    /// height feels right next to Bill's 1.9 × 111 ≈ 211pt.
    let displayScale: CGFloat
    /// Bundled dialogue JSON name (without extension). `nil` = the default
    /// `dialogue.json` — Bill's own pools, untouched.
    let dialogueResource: String?
    /// True when the character should stay on the desktop floor — plain
    /// left/right walks, no leaping onto windows, no climbing, no drops.
    /// Undertale/OneShot characters are grounded (their walks are flat,
    /// four-frame cycles; airborne poses read as glitches); the Knight and
    /// Hornet keep full platformer physics, and so does Bill.
    let prefersGroundedRoaming: Bool
    /// A planted character — never roams at all (Flowey is a flower).
    let prefersStationary: Bool
    /// True for Hollow Knight enemies spawned by the enemy toggle —
    /// they can fly, collide with the main character, and have their
    /// own short dialogue quips.
    let isEnemy: Bool
    /// True for Hollow Knight NPCs — they have fuller dialogue pools
    /// than enemies but the same physics as the main character.
    let isNPC: Bool
    /// The second character that appears alongside this one when the pack
    /// defines a pair (Sans brings Papyrus, the Knight brings Hornet).
    let companionID: String?
    /// Sprite credit line — every pack's art must be attributed.
    let credit: String

    /// Convenience for roster entries — see `prefersGroundedRoaming`.
    init(
        id: String, displayName: String, packID: String, packName: String,
        spritePrefix: String, canvasSize: CGSize, displayScale: CGFloat,
        dialogueResource: String?, companionID: String? = nil,
        prefersGroundedRoaming: Bool = false, prefersStationary: Bool = false,
        isEnemy: Bool = false, isNPC: Bool = false,
        credit: String = "Hollow Knight sprites from community rips (The Spriters Resource)"
    ) {
        self.id = id
        self.displayName = displayName
        self.packID = packID
        self.packName = packName
        self.spritePrefix = spritePrefix
        self.canvasSize = canvasSize
        self.displayScale = displayScale
        self.dialogueResource = dialogueResource
        self.companionID = companionID
        self.prefersGroundedRoaming = prefersGroundedRoaming
        self.prefersStationary = prefersStationary
        self.isEnemy = isEnemy
        self.isNPC = isNPC
        self.credit = credit
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: CharacterDefinition, rhs: CharacterDefinition) -> Bool { lhs.id == rhs.id }

    var isBill: Bool { id == "bill" }
}

/// The full playable roster, grouped by pack. The menu bar's Character
/// submenu is generated from this — adding a character is one entry here
/// plus its sprite families and dialogue file.
@MainActor
enum CharacterRoster {
    static let bill = CharacterDefinition(
        id: "bill",
        displayName: "Bill Cipher",
        packID: "bill",
        packName: "Gravity Falls",
        spritePrefix: "bill",
        canvasSize: CGSize(width: 118, height: 111),
        displayScale: 1.9,
        dialogueResource: nil,
        companionID: nil,
        credit: "Bill Cipher artwork by Kelly Nora (@kiernenking); sprite sheet by JayHyperStarX — deviantart.com/jayhyperstarx"
    )

    // MARK: Undertale

    static let sans = CharacterDefinition(
        id: "sans", displayName: "Sans", packID: "undertale", packName: "Undertale",
        spritePrefix: "sans", canvasSize: CGSize(width: 31, height: 33), displayScale: 4.0,
        dialogueResource: "dialogue_sans", companionID: nil,
        prefersGroundedRoaming: true,
        credit: "Undertale sprites ripped by asym — spriters-resource.com (The Spriters Resource)"
    )
    static let frisk = CharacterDefinition(
        id: "frisk", displayName: "Frisk", packID: "undertale", packName: "Undertale",
        spritePrefix: "frisk", canvasSize: CGSize(width: 25, height: 32), displayScale: 4.0,
        dialogueResource: "dialogue_frisk", companionID: nil,
        prefersGroundedRoaming: true,
        credit: "Undertale sprites ripped by asym — spriters-resource.com"
    )
    static let flowey = CharacterDefinition(
        id: "flowey", displayName: "Flowey", packID: "undertale", packName: "Undertale",
        spritePrefix: "flowey", canvasSize: CGSize(width: 28, height: 23), displayScale: 4.0,
        dialogueResource: "dialogue_flowey", companionID: nil,
        prefersGroundedRoaming: true, prefersStationary: true,
        credit: "Undertale sprites ripped by asym — spriters-resource.com"
    )
    static let temmie = CharacterDefinition(
        id: "temmie", displayName: "Temmie", packID: "undertale", packName: "Undertale",
        spritePrefix: "temmie", canvasSize: CGSize(width: 52, height: 48), displayScale: 4.0,
        dialogueResource: "dialogue_temmie", companionID: nil,
        prefersGroundedRoaming: true,
        credit: "Undertale sprites ripped by asym — spriters-resource.com"
    )
    static let monsterkid = CharacterDefinition(
        id: "monsterkid", displayName: "Monster Kid", packID: "undertale", packName: "Undertale",
        spritePrefix: "monsterkid", canvasSize: CGSize(width: 25, height: 31), displayScale: 4.0,
        dialogueResource: "dialogue_monsterkid", companionID: nil,
        prefersGroundedRoaming: true,
        credit: "Undertale sprites ripped by asym — spriters-resource.com"
    )
    static let annoyingdog = CharacterDefinition(
        id: "annoyingdog", displayName: "Annoying Dog", packID: "undertale", packName: "Undertale",
        spritePrefix: "annoyingdog", canvasSize: CGSize(width: 29, height: 21), displayScale: 4.0,
        dialogueResource: "dialogue_annoyingdog", companionID: nil,
        prefersGroundedRoaming: true,
        credit: "Undertale sprites ripped by asym — spriters-resource.com"
    )


    static let papyrus = CharacterDefinition(
        id: "papyrus", displayName: "Papyrus", packID: "undertale", packName: "Undertale",
        spritePrefix: "papyrus", canvasSize: CGSize(width: 35, height: 47), displayScale: 4.0,
        dialogueResource: "dialogue_papyrus", companionID: nil, prefersGroundedRoaming: true,
        credit: "Undertale sprites ripped by asym — spriters-resource.com"
    )

    static let toriel = CharacterDefinition(
        id: "toriel", displayName: "Toriel", packID: "undertale", packName: "Undertale",
        spritePrefix: "toriel", canvasSize: CGSize(width: 33, height: 58), displayScale: 3.56,
        dialogueResource: "dialogue_toriel", companionID: nil, prefersGroundedRoaming: true,
        credit: "Undertale sprites ripped by asym — spriters-resource.com"
    )
    static let sansdt = CharacterDefinition(
        id: "sansdt", displayName: "Sans (Battle)", packID: "undertale", packName: "Undertale",
        spritePrefix: "sansdt", canvasSize: CGSize(width: 31, height: 33), displayScale: 4.0,
        dialogueResource: "dialogue_sans", companionID: nil, prefersGroundedRoaming: true,
        credit: "Custom Deltarune battle-style Sans by askywalker — spriters-resource.com"
    )

    // MARK: OneShot

    static let niko = CharacterDefinition(
        id: "niko", displayName: "Niko", packID: "oneshot", packName: "OneShot",
        spritePrefix: "niko", canvasSize: CGSize(width: 28, height: 32), displayScale: 4.0,
        dialogueResource: "dialogue_niko", companionID: nil,
        prefersGroundedRoaming: true,
        credit: "OneShot sprites ripped by accuratejaney — spriters-resource.com"
    )

    // MARK: Hollow Knight

    static let knight = CharacterDefinition(
        id: "knight", displayName: "The Knight", packID: "hollowknight", packName: "Hollow Knight",
        spritePrefix: "knight", canvasSize: CGSize(width: 349, height: 186), displayScale: 0.99,
        dialogueResource: "dialogue_knight", companionID: nil,
        credit: "Hollow Knight sprites from the community atlas rips — spriters-resource.com"
    )
    /// The Deepnest weaverling — built verbatim from its labeled named
    /// frames (idle, crawl, crawl_turn, idle_to_crawl).
    static let weaver = CharacterDefinition(
        id: "weaver", displayName: "Weaver", packID: "hollowknight", packName: "Hollow Knight",
        spritePrefix: "weaver", canvasSize: CGSize(width: 477, height: 417), displayScale: 0.44,
        dialogueResource: nil, companionID: nil,
        prefersGroundedRoaming: true,
        isNPC: true,
        credit: "Hollow Knight sprites from community rips (The Spriters Resource)"
    )
    static let hornet = CharacterDefinition(
        id: "hornet", displayName: "Hornet", packID: "hollowknight", packName: "Hollow Knight",
        spritePrefix: "hornet", canvasSize: CGSize(width: 381, height: 249), displayScale: 0.74,
        dialogueResource: "dialogue_hornet", companionID: nil,
        credit: "Hollow Knight sprites from the community atlas rips — spriters-resource.com"
    )

    // MARK: Deltarune

    static let kris = CharacterDefinition(
        id: "kris", displayName: "Kris", packID: "deltarune", packName: "Deltarune",
        spritePrefix: "kris", canvasSize: CGSize(width: 25, height: 41), displayScale: 4.0,
        dialogueResource: "dialogue_kris", companionID: nil,
        credit: "Deltarune sprites ripped by asym, Eli101gamer, KoolTimYT, MrDoubleA, Sissel, Yuti, Bubbled — spriters-resource.com"
    )
    static let ralsei = CharacterDefinition(
        id: "ralsei", displayName: "Ralsei", packID: "deltarune", packName: "Deltarune",
        spritePrefix: "ralsei", canvasSize: CGSize(width: 93, height: 49), displayScale: 4.0,
        dialogueResource: "dialogue_ralsei", companionID: nil,
        credit: "Deltarune sprites ripped by asym, Luxandre, Sissel, TattleameliaMLG — spriters-resource.com"
    )
    static let susie = CharacterDefinition(
        id: "susie", displayName: "Susie", packID: "deltarune", packName: "Deltarune",
        spritePrefix: "susie", canvasSize: CGSize(width: 71, height: 49), displayScale: 4.0,
        dialogueResource: "dialogue_susie", companionID: nil,
        credit: "Deltarune sprites ripped by asym, Sissel, TattleameliaMLG — spriters-resource.com"
    )

    /// Menu/display order — hand-written leads first, then every generated
    /// Hollow Knight enemy and NPC (see `GeneratedRoster.swift`).
    static let all: [CharacterDefinition] = [
        bill,
        sans, sansdt, papyrus, toriel, frisk, flowey, temmie, monsterkid, annoyingdog,
        niko,
        knight, hornet, weaver,
        kris, ralsei, susie,
    ] + generatedEnemies

    static func character(_ id: String) -> CharacterDefinition {
        all.first { $0.id == id } ?? bill
    }

    /// Pack groupings for the menu, in display order.
    static var packs: [(name: String, characters: [CharacterDefinition])] {
        var order: [String] = []
        var groups: [String: [CharacterDefinition]] = [:]
        for c in all where !c.isBill {
            if groups[c.packID] == nil { order.append(c.packID) }
            groups[c.packID, default: []].append(c)
        }
        return order.map { ($0, groups[$0]!) }
    }
}
