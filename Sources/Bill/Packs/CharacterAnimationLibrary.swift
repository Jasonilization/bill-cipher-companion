import SpriteKit

/// Maps the universal `BillState` space onto one character's sprite
/// families — the pack counterpart of `AnimationClipLibrary`.
///
/// Design rules, mirroring the ones that library learned the hard way:
///
/// 1. A non-continuous state always plays `loop: .once` so the state
///    machine's auto-settle timer arms (see `AnimationClipLibrary`'s
///    rule 1).
/// 2. Continuous loops that pingpong use `pingpongLoop` — never native
///    `.pingpong` — to avoid the turnaround stutter (rule 2).
/// 3. States without dedicated art degrade gracefully: they reuse the
///    character's closest family or fall back to transform-only clips on
///    the idle texture — exactly how Bill's `talking` worked before the
///    sheet audit found its frames. A character with fewer families than
///    Bill's 68 still reacts to EVERY trigger; the emotion just plays on
///    whatever pose fits.
@MainActor
final class CharacterAnimationLibrary {
    let catalog: CharacterSpriteCatalog
    /// Which screen axis a stroll is currently moving along — the
    /// four-directional Undertale-style world plays "up"/"down" rows
    /// on vertical legs instead of side walks.
    enum WalkAxis { case horizontal, vertical }
    var walkAxis: WalkAxis = .horizontal
    /// The current horizontal walk direction (-1 = left, +1 = right).
    /// Set by the roaming controller on direction changes so the
    /// walking state can play the direction-correct animation
    /// ("left" vs "right" are DIFFERENT frames on the sheet, not mirrors).
    var walkDirection: Int = 1

    /// True when the sheet has genuinely directional walk rows (separate
    /// "left"/"right" art) — when set, walking right plays the sheet's own
    /// right-facing frames rather than mirroring the left walk.
    var hasDirectionalWalk: Bool {
        let leftKeys = ["left", "walk-left", "left-walk", "black-left-walk"]
        let rightKeys = ["right", "walk-right", "right-walk", "black-right-walk"]
        let hasLeft = leftKeys.contains { !catalog.frames($0).isEmpty }
        let hasRight = rightKeys.contains { !catalog.frames($0).isEmpty }
        return hasLeft && hasRight
    }

    /// True when the sheet has all four directions' walk rows — the
    /// character roams the desktop top-down (no gravity, four-way
    /// strolls) rather than pacing the floor.
    var hasFourDirectionalWalk: Bool {
        guard hasDirectionalWalk else { return false }
        let downKeys = ["down", "walk-forward", "forward-walk", "forward",
                        "light-walk-down", "walk-down", "walk-down-dark-face"]
        let upKeys = ["up", "walk-back", "backwards-walk", "walk-backwards",
                      "butler-walk-up", "light-walk-up", "walk-up", "walk-up-dark",
                      "walk-back-dark"]
        let hasDown = downKeys.contains { !catalog.frames($0).isEmpty }
        let hasUp = upKeys.contains { !catalog.frames($0).isEmpty }
        return hasDown && hasUp
    }

    /// The family the `.showcasing` state is currently performing.
    /// Set by the engine right before requesting the state — the clip
    /// provider reads it, so an arbitrary sheet row can be played and
    /// seen without inventing a BillState for each one.
    var showcaseFamily: String?

    /// Every family on the sheet — the "see all animations" catalog.
    var allFamilies: [String] {
        catalog.familyNames
    }

    /// Families the showcase beat may perform. Labeled walk VARIANTS are
    /// included — for sheet-rich characters like Niko the walk combos ARE
    /// the variety ("she has a variety of walking animations"). Only the
    /// four core directionals and the rest pose are excluded (they belong
    /// to actual movement).
    var showcaseCandidates: [String] {
        allFamilies.filter { fam in
            guard !["idle", "idle_still", "down", "left", "right", "up"].contains(fam) else { return false }
            // Death/impairment poses are never idle theatre — the Knight
            // keeling over dead at random reads as a crash, not a show.
            guard !fam.contains("death"), fam != "stun", fam != "spike" else { return false }
            // Overlay effects are not standalone performances — they play
            // composited on top of their body animation only.
            return !fam.hasPrefix("fx-")
        }
    }

    /// Body family → its labeled overlay effect (the zip's `_ effects/`
    /// folders) + the DELAY before the effect fires, measured from the
    /// body frames: each effect belongs to its animation's action moment
    /// (extent-spike analysis; the nail slash swings at frame ~13 of 26,
    /// the dash lunges at frame ~3, the superdash releases at ~13).
    /// Effects play at 0.06s/frame, one-shot bodies at 0.12s.
    private static let overlayFamilies: [String: (fx: String, delay: TimeInterval)] = [
        "nail_slash": ("fx-matntis_slash_left", 1.44),  // swing at f13; the clean 4f left arc (body canvas)
        "up_slash": ("fx-mantis_up_slash", 0.12),       // the MANTIS CLAW arcs
        "down_slash_v2": ("fx-mantis_down_slash", 0.12),
        "cyclone_slash": ("fx-cyclone_slash_effect", 0.12),
        "charge_slash": ("fx-charge_slash_effect", 0.24),
        "superdash": ("fx-superdash_effect", 1.44),    // release at f13
        "dash_v2": ("fx-dash_effect", 0.24),           // lunge at f3
        "shadow_dash": ("fx-shadow_dash_trail", 0),    // continuous trail
        "focus_v2": ("fx-nail_charge_effect", 0),
        "collect_normal": ("fx-bling", 0),            // the geo sparkle
        "superdash_wall_hit": ("fx-wall_puff", 0),    // wall-contact dust
    ]

    /// The effect clip to composite over the body animation for `state` —
    /// resolved through the same family the body clip will play, so a
    /// Settings reassignment that changes the body family automatically
    /// carries its effect along.
    func overlayClip(for state: BillState) -> AnimationClip? {
        guard let bodyFamily = resolvedFamily(for: state),
              let effect = Self.overlayFamilies[bodyFamily],
              let mapped = resolveFamily(effect.fx),
              mapped == effect.fx,
              !catalog.frames(effect.fx).isEmpty
        else { return nil }
        return AnimationClip(
            textures: catalog.frames(effect.fx),
            frameDuration: 0.06,
            loop: .once,
            overlayDelay: effect.delay
        )
    }

    /// The family a state resolves to (name only) — the same ladder the
    /// clip builder uses, minus the custom-assignment shortcut so the
    /// overlay always follows the character's OWN body family mapping.
    private func resolvedFamily(for state: BillState) -> String? {
        let id = catalog.definition.id
        // The explicit label table only — no ladder, no extras, no
        // invented fallbacks. A state not in the character's table has
        // no family, period.
        guard let family = Self.statesByCharacter[id]?[state],
              !catalog.frames(family).isEmpty
        else { return nil }
        return family
    }

    /// The states this character ACTUALLY has, from their labels: the
    /// explicit table's states, plus walking/running (directional label
    /// rows) and idle (the rest family). The engine gates every beat,
    /// rare roll and reaction on this — a character without a label for
    /// a state never plays it (no placeholder anything).
    var availableStates: Set<BillState> {
        var states: Set<BillState> = []
        if let mapped = Self.statesByCharacter[catalog.definition.id] {
            states.formUnion(mapped.keys)
        }
        if hasDirectionalWalk { states.insert(.walking) }
        states.insert(.idle)
        return states
    }

    /// True when the character has real art for `state` — the engine's
    /// gate before requesting anything.
    func hasArt(for state: BillState) -> Bool {
        if state == .showcasing { return true }
        return availableStates.contains(state)
    }

    init(catalog: CharacterSpriteCatalog) {
        self.catalog = catalog
    }

    // MARK: - Family resolution

    /// The family a state should play, before existence checks. Specials
    /// are per-character families that exist in some packs; the fallback
    /// ladder keeps every state resolvable.
    /// Resolves a state's intended family to whatever name this character
    /// actually uses. The workbench-labeled characters named their
    /// animations with game-natural names (down/left/right for directions,
    /// battle-idle for combat, etc.) — this maps them back.
    private func resolveFamily(_ requested: String) -> String? {
        // Direct match
        if !catalog.frames(requested).isEmpty { return requested }
        // Alternative names the workbench labels commonly use
        let alternatives: [String: [String]] = [
            "idle": ["down", "default", "defualt", "idle-still", "idle_still",
                     "battle-idle", "defualt", "forward", "forward-walk",
                     "in-battle-light", "defualt"],
            "walking": ["walk-left", "walk-right", "left-walk", "right-walk",
                        "left", "right",
                        "walk-forward", "forward-walk", "walk-back",
                        "walk-backwards", "walk-up", "backwards-walk",
                        "darkw-walk-left", "darkw-walk-right",
                        "darkw-walk-forward", "darkw-walk-back",
                        "white-walk-left", "white-walk-right",
                        "white-walk-forward", "white-walk-back",
                        "redoutline-walk-left", "redoutline-walk-right",
                        "redoutline-walk-forward", "redoutline-walk-back",
                        "light-walk-left", "light-walk-right",
                        "light-walk-down", "light-walk-up",
                        "light-walk-forward",
                        "mask-walk-left", "mask-walk-right",
                        "mask-walk-forward", "mask-walk-backwards",
                        "dark-walk-left", "dark-walk-right",
                        "dark-walk-backwards",
                        "black-left-walk", "black-right-walk",
                        "black-forward-walk",
                        "black-mask-walk-left", "black-mask-walk-right",
                        "dark-mask-walk-right", "dark-mask-walk-backwards",
                        "dark-light-walk-left", "dark-light-walk-right",
                        "dark-light-walk-backwards",
                        "dark-light-mask-walk-left", "dark-light-mask-walk-right",
                        "dark-light-mask-walk-backwards",
                        "black-light-walk-left", "black-light-walk-right",
                        "black-light-walk-backwards",
                        "no-mask-black-light-walk-left", "no-mask-black-light-walk-right",
                        "no-mask-black-light-walk-backwards",
                        "mask-light-walk-left", "mask-light-walk-right",
                        "mask-light-walk-backwards",
                        "confident-walk", "walk", "tail-fire-walk",
                        "butler-walk-left", "butler-wakl-right",
                        "walk-left-dark", "walk-right-dark",
                        "walk-back-dark",
                        "walk-left-dark-face", "walk-right-dark-face",
                        "walk-left-no-face", "walk-right-no-face",
                        "walk-forward-no-face",
                        "walk-backwards-no-face",
                        "blush-walk-left", "blush-walk-right",
                        "walk-left-with-blush", "walk-right-with-blush",
                        "walk-forward-w-blush",
                        "walk"],
            "talking": ["talk", "battle-act", "act", "talk-fast",
                        "point-and-talk", "talk-left", "talk-right"],
            "running": ["run", "dash", "sprint", "tail-fire-walk"],
            "sleeping": ["sleep", "furry-tail-sleep", "sit",
                         "sleep-bark", "sleepy", "sleeep",
                         "tail-fire-sleep", "sit"],
            "happy": ["happy-dog", "happy-2", "happy", "dance", "dance-light",
                      "eat-bone", "eat-candy"],
            "surprised": ["battle-idle-shocked-face-left", "shocked",
                          "surprised", "scared-and-fall", "battle-idle-shocked-face-left"],
            "annoyed": ["stressed", "angry", "grumpEyes"],
            "celebrating": ["dance", "dance-light", "pirroute", "bow",
                            "light-bow", "spin-scarf", "wave-hi"],
            "confused": ["battle-idle-shocked-face-left", "scared-and-fall"],
            "dazed": ["shocked", "downed", "hurt", "hit"],
            "poked": ["shocked", "battle-idle-shocked-face-left", "scared-and-fall"],
        ]
        if let alts = alternatives[requested] {
            for alt in modeOrdered(alts) {
                if !catalog.frames(alt).isEmpty { return alt }
            }
        }
        // World-mode variants of the requested name itself ("idle" exists
        // as plain but the character is in dark mode → prefer a dark idle
        // row when the sheet carries one).
        for suffix in worldMode == "dark" ? ["-dark", "-in-battle-dark"] : ["-light", "-in-battle-light"] {
            let variant = requested + suffix
            if !catalog.frames(variant).isEmpty { return variant }
        }
        return nil
    }

    /// The world mode the user picked for this character in Settings
    /// ("light" / "dark"); Deltarune sheets carry both forms' rows.
    private var worldMode: String? {
        AppPreferences.worldModeMapShared[catalog.definition.id]
    }

    /// Prefers mode-matching variants: dark mode picks "dark*"/"*-dark"
    /// families first, light mode picks "light*"/plain ones first.
    private func modeOrdered(_ candidates: [String]) -> [String] {
        guard let mode = worldMode else { return candidates }
        let wantsDark = mode == "dark"
        // Read the actor-isolated shared table ONCE, in the method body —
        // the sorted predicate closure below is nonisolated and may only
        // touch this captured local.
        let worldLabels = AppPreferences.familyWorldMapShared
        func rank(_ f: String) -> Int {
            // The user's explicit per-family world label (Settings →
            // Animations browser) outranks name-based guessing.
            switch worldLabels[f] {
            case "dark": return wantsDark ? 0 : 3
            case "light": return wantsDark ? 3 : 0
            default: break
            }
            // Ralsei's butler rows are her dark-world outfit.
            let isDark = f.contains("dark") || f.hasPrefix("darkw") || f.contains("butler")
            let isLight = f.contains("light") && !isDark
            return wantsDark ? (isDark ? 1 : (isLight ? 2 : 1))
                             : (isLight ? 1 : (isDark ? 2 : 1))
        }
        let ranked = candidates.map { (family: $0, rank: rank($0)) }
        return ranked
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.family < $1.family }
            .map(\.family)
    }

    private func family(for state: BillState) -> String {
        switch state {
        case .idle: return "idle"
        case .walking, .running: return "walking"
        case .talking: return "talking"
        case .sleeping: return "sleeping"
        case .coding, .gaming, .channeling: return "coding"
        case .charging: return "charging"
        case .heatingUp: return "heating"
        case .happy, .celebrating: return "happy"
        case .annoyed, .huffy, .watched, .grumpEyes: return "annoyed"
        case .surprised, .spooked, .ambushed, .flinching: return "surprised"
        case .confused, .dazed, .thinking: return "surprised"
        case .poked: return "idle"
        case .smug, .focused, .caneFlourish: return "happy"
        // Roaming beats ride the locomotion families.
        case .crouching, .launching, .rising, .falling,
             .landingSoft, .landingHard, .ledgeGrabbing,
             .climbingUp, .climbingDown, .hangingIdle, .edgePeek:
            return "walking"
        // Rare Easter eggs / big beats: per-character specials when they
        // exist (knight attack, undyne attack, flowey evil…), otherwise
        // the character's strongest pose.
        case .powerSurge, .zodiacVision, .summonRitual, .ritualBuildup,
             .ghostPale, .glitchForm, .shadowHands, .meltdown,
             .zodiacRage, .prismDance, .zodiacCrimson,
             .rampaging, .zipAround, .dashTarget, .tumbling, .conjuring,
             .caneTwist, .hookCane:
            return "happy"
        case .trickster, .darkWorld, .hollowed, .cultLeader, .scanning,
             .sneaking, .glitching, .charged, .transferring, .summoning,
             .sculpting, .kinship, .fractaling, .presenting, .guilty,
             .dreading, .grooving, .dispatching, .stressed,
             .pushingCode, .browsingStore, .dancing:
            return "annoyed"
        case .showcasing:
            return "idle"
        }
    }

    /// Specials that only some characters ship with — checked before the
    /// generic ladder so e.g. the Knight's attack actually plays its
    /// seventeen-frame nail arc.
    /// THE explicit state map, hand-written from each character's actual
    /// labels (workbench_export.json / verbatim zip folder names). A state
    /// listed here plays its family; a state NOT listed simply does not
    /// exist for that character — no borrowed families, no placeholder
    /// stand-ins (Niko has walks and spins, so Niko never plays
    /// "surprised"). This is the single place pack characters are mapped.
    private static let statesByCharacter: [String: [BillState: String]] = [
        // === Hollow Knight — VERBATIM zip folder / named-frame labels ===
        "knight": [
            // The three SPELLS each own a state so they actually play:
            // Vengeful Spirit, Howling Wraiths, Desolate Dive (the spell
            // VFX themselves are not in the zip — only nail/dash/charge/
            // geo effects were ripped; these are the full cast poses).
            .powerSurge: "cast", .zodiacVision: "scream_cast_lvl_02",
            .summonRitual: "quake", .heatingUp: "quake_cast_level_02_shadow",
            .conjuring: "cast_v03", .channeling: "cast_level_02",
            .rampaging: "nail_slash", .zipAround: "shadow_dash",
            .sleeping: "sit", .charging: "focus_v2",
            .dazed: "stun", .thinking: "focus_v2", .caneFlourish: "focus_v2",
            .focused: "focus_v2", .dashTarget: "dash_v2",
            .falling: "fall", .landingSoft: "land", .landingHard: "hard_land",
            .launching: "jump", .rising: "jump", .edgePeek: "look_down",
            .ledgeGrabbing: "wall_slide", .hangingIdle: "wall_slide",
            .climbingUp: "wall_slide", .climbingDown: "wall_slide",
            .gaming: "sit_map_write", .coding: "sit_map_look",
            .happy: "look_up",
        ],
        "hornet": [
            .powerSurge: "throw_side", .zipAround: "jump",
            .rampaging: "throw_side",
            .landingHard: "hard_land", .landingSoft: "hard_land",
            .launching: "jump", .rising: "jump", .falling: "jump",
        ],
        "weaver": [
            .walking: "crawl", .running: "crawl", .zipAround: "crawl",
            .falling: "crawl", .edgePeek: "idle_to_crawl",
        ],

        // === Undertale — workbench labels, nothing else ===
        "sans": [
            .confused: "shrug",          // his shrug
            .sleeping: "sleep",
        ],
        "sansdt": [
            .talking: "talk", .happy: "happy", .annoyed: "annoyed",
            .surprised: "surprised",    // the label exists verbatim
            .dazed: "dazed", .confused: "nervous", .focused: "serious",
            .celebrating: "grin", .powerSurge: "eyeflash",  // THE eye flash
        ],
        "papyrus": [
            .happy: "silly", .smug: "admiration",
        ],
        "toriel": [BillState: String](),               // walks + the chair (showcase)
        "frisk": [BillState: String](),                // walks (+ drop-water/rain, showcase)
        "flowey": [
            .powerSurge: "face-grow",  // the iconic evil grin
            .talking: "talking",
        ],
        "temmie": [
            .talking: "talk",
        ],
        "annoyingdog": [
            .happy: "happy", .sleeping: "sleepy",
        ],
        "monsterkid": [
            .tumbling: "right-face-fall-stand-left-face-fall",  // the trip
        ],

        // === Deltarune — workbench labels ===
        "kris": [
            .powerSurge: "battle-attack-intro", .dazed: "hurt",
            .grooving: "dance",
        ],
        "ralsei": [
            .powerSurge: "attack", .surprised: "battle-idle-shocked-face-left",
            .happy: "laugh", .channeling: "heal", .grooving: "dance",
            .celebrating: "dance-light", .falling: "falling",
            .thinking: "fiddle-with-glasses",
        ],
        "susie": [
            .powerSurge: "rude-buster", .happy: "laugh", .dazed: "hit",
            .grooving: "dancing",
        ],

        // === OneShot ===
        "niko": [BillState: String](),  // walks and spins, exactly as labeled — nothing else
    ]

    // MARK: - Full-sheet extras

    /// The states that spread across the character's "x" families — every
    /// reaction, flourish and egg gets its OWN sheet animation instead of
    /// piling onto happy/annoyed/surprised. This is the "you never used all
    /// the animations" fix: a character with 48 wired rows plays 48
    /// distinct beats.
    private static let extraStates: [BillState] = [
        .trickster, .darkWorld, .hollowed, .cultLeader, .scanning,
        .sneaking, .glitching, .charged, .transferring, .summoning,
        .sculpting, .kinship, .fractaling, .presenting, .guilty,
        .dreading, .grooving, .dispatching, .ambushed, .stressed,
        .watched, .flinching, .huffy, .pushingCode, .browsingStore, .dancing,
        .caneTwist, .hookCane, .conjuring, .tumbling, .dashTarget,
        .grumpEyes, .zipAround, .celebrating, .confused, .dazed, .smug,
        .focused, .heatingUp, .channeling, .powerSurge, .zodiacVision,
        .summonRitual, .ritualBuildup, .ghostPale, .glitchForm, .prismDance,
        .rampaging,
    ]

    /// How many "x" families this character ships — probed by file
    /// existence, never by loading textures (48 families × 16 frames of
    /// Knight art would be ~100MB if the probe decoded them all).
    static func extraFamilyCount(definition: CharacterDefinition) -> Int {
        var count = 0
        for n in 1...60 {
            let name = String(format: "%@_x%02d_01", definition.spritePrefix, n)
            guard Bundle.module.url(
                forResource: name,
                withExtension: "png",
                subdirectory: "Packs/\(definition.packID)/Sprites"
            ) != nil else { break }
            count = n
        }
        return count
    }

    /// The distinct extra family for `state`, or `nil` when this character
    /// has none (or the family it maps to is empty). Cyclic assignment —
    /// every state in `extraStates` lands on a different row.
    private func extraFamily(for state: BillState) -> String? {
        let count = Self.extraFamilyCount(definition: catalog.definition)
        guard count > 0 else { return nil }
        guard let index = Self.extraStates.firstIndex(of: state) else { return nil }
        for probe in 0..<count {
            let n = (index + probe) % count + 1
            let family = String(format: "x%02d", n)
            if !catalog.frames(family).isEmpty {
                return family
            }
        }
        return nil
    }

    /// True when this state would play one of the auto-wired sheet "x"
    /// rows — outfit variants (Niko's gas mask), dark-world forms
    /// (Ralsei/Susie/Kris), flip rows (Monster Kid). Ambient idle beats
    /// refuse those (`CharacterEngine.isAmbientSafe`): extras fire on real
    /// triggers only, never in the random rotation, so nobody shape-shifts
    /// while just standing around.
    func usesExtraFamily(for state: BillState) -> Bool {
        extraFamily(for: state) != nil
    }

    // MARK: - Clip building

    func clip(for state: BillState) -> AnimationClip {
        let id = catalog.definition.id

        // The showcase state plays whatever family the engine staged.
        if state == .showcasing, let family = showcaseFamily,
           !catalog.frames(family).isEmpty {
            return clip(for: state, family: family)
        }

        // User assignment from the Settings animations browser wins over
        // everything — "this reaction plays THAT row" is the whole point
        // of the assign-to-trigger UI.
        if let chosen = AppPreferences.customFamilyMapShared[state.rawValue],
           !chosen.isEmpty,
           !catalog.frames(chosen).isEmpty {
            return clip(for: state, family: chosen)
        }

        // The explicit label table: a pack character's ONLY state→family
        // source. No ladder, no extras auto-claiming unlabeled rows, no
        // borrowed families — "absolute equal to the json file".
        if let explicit = resolvedFamily(for: state) {
            return clip(for: state, family: explicit)
        }

        // Idle settles onto the rest chain (each character's real rest
        // label: sans "down", kris "battle-idle", knight "idle_still"…).
        if state == .idle || state == .poked {
            for candidate in ["idle", "idle_still", "battle-idle", "down",
                              "forward-walk", "default", "defualt"] {
                if !catalog.frames(candidate).isEmpty {
                    return clip(for: state, family: candidate)
                }
            }
            return AnimationClip(textures: [catalog.restTexture], frameDuration: 0.2, loop: .loop)
        }

        // A state with no label for this character plays NOTHING — a
        // no-op clip, not a placeholder bob, not someone else's family.
        return AnimationClip(textures: [], frameDuration: 0.2, loop: .once)
    }

    /// The facing the user labeled for this family in Settings:
    /// "right" mirrors left-authored art when it plays, "left" pins it
    /// un-mirrored, absent = automatic.
    private func facingLabel(for family: String) -> String? {
        AppPreferences.familyFacingMapShared[family]
    }

    private func clip(for state: BillState, family: String) -> AnimationClip {
        var clip = buildClip(for: state, family: family)
        if facingLabel(for: family) == "right" {
            clip.mirrored = true
        }
        return clip
    }

    private func buildClip(for state: BillState, family: String) -> AnimationClip {
        let frames = catalog.frames(family)
        let isContinuous = state.isContinuous
        let fast: TimeInterval = 0.12
        let slow: TimeInterval = 0.22

        // No frames at all: transform-only clips so the beat still reads.
        if frames.isEmpty {
            switch state {
            case .walking, .running:
                return AnimationClip(
                    textures: [catalog.restTexture],
                    frameDuration: 0.2,
                    transform: [.body: [
                        PoseKeyframe(duration: 0.32, offset: CGVector(dx: 0, dy: 3), timing: .easeInEaseOut),
                        PoseKeyframe(duration: 0.32, offset: .zero, timing: .easeInEaseOut),
                    ]],
                    loop: .loop)
            case .sleeping:
                return AnimationClip(
                    textures: [catalog.restTexture],
                    frameDuration: 0.3,
                    transform: [.body: [
                        PoseKeyframe(duration: 1.6, offset: CGVector(dx: 0, dy: -2)),
                        PoseKeyframe(duration: 1.6, offset: .zero),
                    ]],
                    loop: .pingpong)
            case .talking:
                return AnimationClip(
                    textures: [catalog.restTexture],
                    frameDuration: 0.15,
                    transform: [.body: [
                        PoseKeyframe(duration: 0.22, offset: CGVector(dx: 0, dy: 2)),
                        PoseKeyframe(duration: 0.22, offset: .zero),
                    ]],
                    loop: .loop)
            default:
                // A brief life on a one-shot beat: small hop, settle.
                return AnimationClip(
                    textures: [catalog.restTexture],
                    frameDuration: 0.2,
                    transform: [.body: [
                        PoseKeyframe(duration: 0.14, offset: CGVector(dx: 0, dy: 5), timing: .easeOut),
                        PoseKeyframe(duration: 0.2, offset: .zero, timing: .easeIn),
                    ]],
                    loop: .once)
            }
        }

        if isContinuous {
            switch state {
            case .idle:
                // The ambient breath: texture cycle (if the family has more
                // than one frame) plus the same bob Bill's idle uses.
                let textures = frames.count > 1 ? Self.pingpongLoop(frames) : frames
                return AnimationClip(
                    textures: textures,
                    frameDuration: 0.15,
                    transform: [.body: [
                        PoseKeyframe(duration: 1.4, offset: CGVector(dx: 0, dy: -5), timing: .easeInEaseOut),
                        PoseKeyframe(duration: 1.4, offset: .zero, timing: .easeInEaseOut),
                    ]],
                    loop: .loop)
            case .walking, .running:
                // Four-directional world: vertical legs play the sheet's
                // own up (away) / down (toward) rows.
                if state == .walking, walkAxis == .vertical {
                    let verticalKeys = walkDirection > 0
                        ? ["down", "walk-forward", "forward-walk", "forward",
                           "light-walk-down", "walk-down", "walk-down-dark-face"]
                        : ["up", "walk-back", "backwards-walk", "walk-backwards",
                           "butler-walk-up", "light-walk-up", "walk-up", "walk-up-dark",
                           "walk-back-dark"]
                    for key in modeOrdered(verticalKeys) {
                        if !catalog.frames(key).isEmpty {
                            return AnimationClip(
                                textures: catalog.frames(key),
                                frameDuration: 0.16,
                                transform: [.body: [
                                    PoseKeyframe(duration: 0.32, offset: CGVector(dx: 0, dy: 3), timing: .easeInEaseOut),
                                    PoseKeyframe(duration: 0.32, offset: .zero, timing: .easeInEaseOut),
                                ]],
                                loop: .loop)
                        }
                    }
                }
                // Directional walk: the sheet has SEPARATE left/right
                // animation rows. If we're walking left and a "left"
                // or "walk-left" family exists, play it; same for right.
                // This is the user's explicit labeling — these are NOT
                // mirrors, they are genuinely different sprite art.
                let dir = walkDirection
                let directionalKeys = dir < 0
                    ? ["left", "walk-left", "walk_left", "black-left-walk",
                       "dark-walk-left", "mask-walk-left", "black-mask-walk-left",
                       "left-walk", "walk-left-dark", "dark-light-walk-left",
                       "dark-light-mask-walk-left", "mask-light-walk-left",
                       "no-mask-black-light-walk-left"]
                    : ["right", "walk-right", "walk_right", "black-right-walk",
                       "dark-walk-right", "mask-walk-right", "black-mask-walk-right",
                       "right-walk", "walk-right-dark", "dark-light-walk-right",
                       "dark-light-mask-walk-right", "mask-light-walk-right",
                       "no-mask-black-light-walk-right"]
                if state == .walking {
                    for key in directionalKeys {
                        if !catalog.frames(key).isEmpty {
                            return AnimationClip(
                                textures: catalog.frames(key),
                                frameDuration: 0.16,
                                transform: [.body: [
                                    PoseKeyframe(duration: 0.32, offset: CGVector(dx: 0, dy: 3), timing: .easeInEaseOut),
                                    PoseKeyframe(duration: 0.32, offset: .zero, timing: .easeInEaseOut),
                                ]],
                                loop: .loop)
                        }
                    }
                }
                // Undertale's walk cycles are 2 unique poses (contact/pass)
                // repeated — at Bill's 0.16s they strobe; at amble pace they
                // read as his unhurried shuffle. Running keeps the urgency.
                let uniqueCount = Set(frames.map { ObjectIdentifier($0) }).count
                let isShuffle = uniqueCount <= 2 && frames.count >= 2
                return AnimationClip(
                    textures: isShuffle ? Array(frames.prefix(2)) : frames,
                    frameDuration: state == .running ? fast : (isShuffle ? 0.22 : 0.16),
                    transform: [.body: [
                        PoseKeyframe(duration: 0.32, offset: CGVector(dx: 0, dy: 3), timing: .easeInEaseOut),
                        PoseKeyframe(duration: 0.32, offset: .zero, timing: .easeInEaseOut),
                    ]],
                    loop: .loop)
            case .talking:
                let textures = frames.count > 1 ? Self.pingpongLoop(frames) : frames
                return AnimationClip(textures: textures, frameDuration: 0.15, loop: .loop)
            case .sleeping:
                return AnimationClip(
                    textures: frames,
                    frameDuration: 0.3,
                    transform: [.body: [
                        PoseKeyframe(duration: 1.6, offset: CGVector(dx: 0, dy: -2)),
                        PoseKeyframe(duration: 1.6, offset: .zero),
                    ]],
                    loop: .loop)
            case .falling, .rising, .launching:
                // Physics-driven states: the CLIP must keep pace with the
                // simulation. A 6-frame fall at the default slow pingpong
                // took 2.6s per cycle while the real fall lasts ~0.4s —
                // the animation visibly trailed the character ("falling
                // is laggy"). Forward loop, fast frames.
                return AnimationClip(textures: frames, frameDuration: 0.09, loop: .loop)
            case .climbingUp, .climbingDown:
                return AnimationClip(textures: frames, frameDuration: 0.14, loop: .loop)
            default:
                let textures = frames.count > 1 ? Self.pingpongLoop(frames) : frames
                return AnimationClip(textures: textures, frameDuration: slow, loop: .loop)
            }
        } else {
            // One-shot beats. Multi-frame families play forward and hold
            // their last frame briefly (see `AnimationClipLibrary`'s
            // directional-motion reasoning); single-frame families get a
            // transform accent.
            if frames.count > 1 {
                let held = frames + Array(repeating: frames[frames.count - 1], count: 2)
                return AnimationClip(textures: held, frameDuration: fast, loop: .once)
            }
            switch state {
            case .surprised, .spooked, .ambushed, .poked, .flinching:
                return AnimationClip(
                    textures: frames,
                    frameDuration: 0.2,
                    transform: [.body: [
                        PoseKeyframe(duration: 0.1, offset: CGVector(dx: 0, dy: 4), timing: .easeOut),
                        PoseKeyframe(duration: 0.18, offset: .zero, timing: .easeIn),
                    ]],
                    loop: .once)
            case .happy, .celebrating, .smug:
                return AnimationClip(
                    textures: frames,
                    frameDuration: 0.3,
                    transform: [.body: [
                        PoseKeyframe(duration: 0.25, offset: CGVector(dx: 0, dy: 7), timing: .easeOut),
                        PoseKeyframe(duration: 0.3, offset: .zero, timing: .easeIn),
                    ]],
                    loop: .once)
            default:
                return AnimationClip(textures: frames, frameDuration: 0.2, loop: .once)
            }
        }
    }

    /// `[A,B,C]` → `[A,B,C,B]` — seamless forever-pingpong without the
    /// duplicated turnaround frames (see `AnimationClipLibrary.pingpongLoop`).
    private static func pingpongLoop(_ frames: [SKTexture]) -> [SKTexture] {
        guard frames.count > 2 else { return frames }
        return frames + frames.dropFirst().dropLast().reversed()
    }

    /// Idle variety beats for characters: mapped onto their own families
    /// where possible, otherwise skipped (returning `nil` keeps ambient
    /// idle running — see `BillStateMachine.playIdleVariant`).
    func idleVariant(_ variant: AnimationClipLibrary.IdleVariant) -> AnimationClip? {
        let frames: [SKTexture]
        switch variant {
        case .shiftWeight:
            let idle = catalog.frames("idle")
            guard idle.count > 1 else { return nil }
            return AnimationClip(textures: [idle[idle.count / 2]], frameDuration: 0.9, loop: .once)
        case .stretch, .tiltCheck:
            return nil  // the state machine's transform-only variants cover these
        case .curious:
            frames = catalog.frames("talking")
            guard !frames.isEmpty else { return nil }
            return AnimationClip(textures: Array(frames.prefix(2)), frameDuration: 0.25, loop: .once)
        }
    }
}
