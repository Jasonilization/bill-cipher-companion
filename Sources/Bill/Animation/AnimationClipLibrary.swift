import SpriteKit

/// Which FX layer (if any) a state should show alongside its clip. Kept
/// exactly as it was for the procedural rig — these are abstract particle
/// overlays (steam puffs, sparkles, confetti), not representational vector
/// props, so they don't clash with "pixel-art Bill is the only prop-like
/// visual" the way a hand-drawn vector laptop or controller would.
enum BillFX {
    case steam
    case sparkle
    case zzz
    case confettiAndSparkle
}

/// All of Bill's animation content, built entirely from the pixel-art
/// sprite sheet (`BillSpriteCatalog`) — see `Docs/SpriteAnimationCatalog.md`
/// for what's on the sheet, the annotated-groups analysis, and why each clip
/// below uses what it uses. No procedural vector props are attached to any
/// state; the sprite frames themselves carry the "holding something" or
/// "working" read.
///
/// Two hard rules, both fixing real bugs from earlier passes:
///
/// 1. Every non-continuous (`isContinuous == false`) clip **must** use
///    `loop: .once` — `BillStateMachine.runClip` only schedules the
///    auto-settle-back-to-idle timer for `.once` clips, so a one-shot beat
///    declared with `.loop`/`.pingpong` would play forever (this happened to
///    `celebrating` in the first pass). Clips that want a multi-cycle or
///    "hold the last frame" feel repeat their texture array manually via
///    `pingpong(_:cycles:)` / `holdLast(_:extra:)` instead of relying on the
///    clip's own loop mode.
/// 2. Any *continuous* clip that pingpongs a texture sequence must build its
///    array with `pingpongLoop(_:)`, not `AnimationClip`'s native
///    `loop: .pingpong` — the native implementation plays the array forward
///    then the full reversed array, which repeats both end frames on every
///    single turnaround *and* on every repeat boundary (a visible one-frame
///    stutter, twice per cycle). `pingpongLoop` trims both duplicates so a
///    repeated forever-loop is seamless.
@MainActor
enum AnimationClipLibrary {

    /// Builds a "there and back" (optionally multi-cycle), one-shot frame
    /// sequence without duplicating the turnaround frame — naively appending
    /// `frames.reversed()` repeats the last frame twice in a row, a visible
    /// stutter right at the point the motion reverses. Pair with
    /// `loop: .once` (see rule 1 above).
    private static func pingpong(_ frames: [SKTexture], cycles: Int = 1) -> [SKTexture] {
        guard frames.count > 1 else { return frames }
        let oneCycle = frames + frames.dropLast().reversed()
        guard cycles > 1 else { return oneCycle }
        var result = oneCycle
        for _ in 1..<cycles {
            result += oneCycle.dropFirst()
        }
        return result
    }

    /// Builds a there-and-back sequence meant to be repeated *forever*
    /// (`loop: .loop`) with no stutter at the repeat boundary either — see
    /// rule 2 above. `[A,B,C]` becomes `[A,B,C,B]`, which repeats as
    /// `A,B,C,B,A,B,C,B,…`: each end frame is touched exactly once per pass.
    private static func pingpongLoop(_ frames: [SKTexture]) -> [SKTexture] {
        guard frames.count > 2 else { return frames }
        return frames + frames.dropFirst().dropLast().reversed()
    }

    /// Extends how long the final frame of a one-shot clip stays on screen
    /// by repeating it — simpler than adding per-frame timing to
    /// `AnimationClip`, and `singlePassDuration` (which drives the
    /// auto-settle timer) already accounts for texture count, so the hold
    /// is correctly included in the settle delay for free.
    private static func holdLast(_ frames: [SKTexture], extra: Int) -> [SKTexture] {
        guard let last = frames.last, extra > 0 else { return frames }
        return frames + Array(repeating: last, count: extra)
    }

    static func clip(for state: BillState) -> AnimationClip {
        switch state {
        case .idle: return idle
        case .walking: return walking
        case .talking: return talking
        case .thinking: return thinking
        case .happy: return happy
        case .annoyed: return annoyed
        case .sleeping: return sleeping
        case .gaming: return gaming
        case .coding: return coding
        case .heatingUp: return heatingUp
        case .charging: return charging
        case .surprised: return surprised
        case .celebrating: return celebrating
        case .confused: return confused
        case .dazed: return dazed
        case .poked: return poked
        case .smug: return smug
        case .caneFlourish: return caneFlourish
        case .powerSurge: return powerSurge
        case .zodiacVision: return zodiacVision
        case .summonRitual: return summonRitual
        case .ghostPale: return ghostPale
        case .glitchForm: return glitchForm
        case .shadowHands: return shadowHands
        case .meltdown: return meltdown
        case .channeling: return channeling
        case .focused: return focused
        }
    }

    /// No state attaches a procedural prop anymore — the pixel-art frames
    /// themselves are Bill's entire visual identity now. Kept as a function
    /// (rather than deleting `PropKit`/`equipProp` outright) so the plumbing
    /// stays available if a future pass adds genuinely pixel-art props.
    static func prop(for state: BillState) -> BillProp { .none }

    static func fx(for state: BillState) -> BillFX? {
        switch state {
        case .heatingUp: return .steam
        case .sleeping: return .zzz
        case .celebrating: return .confettiAndSparkle
        case .happy, .smug, .caneFlourish, .meltdown: return .sparkle
        case .powerSurge, .zodiacVision, .summonRitual: return .sparkle
        default: return nil
        }
    }

    // MARK: - Ambient rest

    /// The sheet's own 7-frame idle-float cycle (legs paddling gently),
    /// plus the breathing bob layered on top of it.
    ///
    /// Animation-director audit (see `Docs/SpriteAnimationCatalog.md`): this
    /// clip previously had `transform` only, no `textures` at all — despite
    /// `BillSpriteCatalog.idle` already existing and holding exactly the
    /// frames this state is named for. The only thing that ever touched
    /// those 7 frames was `IdleVariant.shiftWeight`, which plucks a single
    /// middle frame and holds it still; the paddling cycle itself never
    /// played. That's what made Bill "feel like a static sprite" — not a
    /// missing bob, a missing sprite. Runs forever while genuinely idle (see
    /// `BillStateMachine.startAmbientIdle`), layered underneath the
    /// occasional shiftWeight/stretch/tiltCheck/curious variety beats rather
    /// than replacing them.
    static let idle = AnimationClip(
        textures: BillSpriteCatalog.idle,
        frameDuration: 0.15,
        transform: [
            .body: [
                // ~2% of Bill's on-screen height — enough to actually read
                // as breathing at his small display size; a 2pt version of
                // this (tried first) was only 1-2 screen px peak-to-peak
                // and invisible in practice.
                PoseKeyframe(duration: 1.4, offset: CGVector(dx: 0, dy: -5), timing: .easeInEaseOut),
                PoseKeyframe(duration: 1.4, offset: CGVector(dx: 0, dy: 0), timing: .easeInEaseOut),
            ],
        ],
        loop: .pingpong
    )

    // MARK: - Locomotion

    /// A small vertical bob layered under the run-cycle textures — Bill has
    /// no legs planted on the ground in his character design (dangling
    /// limbs on a floating triangle), so a perfectly flat horizontal slide
    /// read as sliding rather than the "small floating creature" hovering
    /// feel called for. Timed to the walk-cycle's own frame rate (4 frames
    /// x 0.16s = 0.64s per cycle, matching this bob's 0.32+0.32s up/down) so
    /// the hover stays in phase with the leg motion instead of drifting.
    ///
    /// `frameDuration` is slower than the sheet's native run-cycle timing on
    /// purpose — the source frames read as a sprint (legs kicking hard, arm
    /// swung back), which is the wrong energy for ambient wandering; slowed
    /// down, the same frames read as an unhurried amble instead. Paired with
    /// `CharacterWindowController`'s wander speed, which was tuned down to
    /// match so his apparent foot-speed and his actual ground-speed agree —
    /// mismatched, it reads as sliding/moonwalking regardless of how correct
    /// the direction-flip is.
    static let walking = AnimationClip(
        textures: BillSpriteCatalog.walk,
        frameDuration: 0.16,
        transform: [
            .body: [
                PoseKeyframe(duration: 0.32, offset: CGVector(dx: 0, dy: 3), timing: .easeInEaseOut),
                PoseKeyframe(duration: 0.32, offset: CGVector(dx: 0, dy: 0), timing: .easeInEaseOut),
            ],
        ],
        loop: .loop
    )

    // MARK: - Conversational

    /// The sheet's hand-raised explaining/waving gesture.
    static let talking = AnimationClip(
        textures: BillSpriteCatalog.talking,
        frameDuration: 0.15,
        loop: .pingpong
    )

    /// The sheet's dedicated hand-to-chin pondering sequence.
    static let thinking = AnimationClip(
        textures: BillSpriteCatalog.thinking,
        frameDuration: 0.35,
        loop: .pingpong
    )

    // MARK: - Emotional beats (single-shot, settle back to idle)

    static let happy = AnimationClip(
        textures: BillSpriteCatalog.happy,
        frameDuration: 0.16,
        loop: .once
    )

    /// The sheet's full escalating point-and-lecture cycle (left-facing,
    /// then a mirrored right-facing repeat) — a genuine "ranting" beat
    /// rather than the 3-frame excerpt the first pass used.
    static let annoyed = AnimationClip(
        textures: holdLast(BillSpriteCatalog.annoyed, extra: 1),
        frameDuration: 0.16,
        loop: .once
    )

    /// Normal → shocked → hat-flies-off, held on the collapse frame.
    static let surprised = AnimationClip(
        textures: holdLast(BillSpriteCatalog.surprised, extra: 4),
        frameDuration: 0.18,
        loop: .once
    )

    /// Four real frames of mounting confusion, not a single static "?" —
    /// the first pass had one frame; the annotated sheet has a full beat.
    static let confused = AnimationClip(
        textures: BillSpriteCatalog.confused,
        frameDuration: 0.18,
        loop: .once
    )

    static let dazed = AnimationClip(
        textures: pingpong(BillSpriteCatalog.dazed),
        frameDuration: 0.22,
        loop: .once
    )

    static let poked = AnimationClip(
        textures: BillSpriteCatalog.poked,
        frameDuration: 0.11,
        loop: .once
    )

    /// A finger-snap ("SNAP!", complete with its own tiny sparkle) leading
    /// into the confident closed-eye grin — two previously-separate ideas
    /// (an attention-getting snap, a satisfied smirk) read naturally as one
    /// beat: Bill snaps, *then* gloats.
    static let smug = AnimationClip(
        textures: holdLast(BillSpriteCatalog.snap + BillSpriteCatalog.smug, extra: 2),
        frameDuration: 0.2,
        loop: .once
    )

    /// A dapper cane flourish — pulled out, twirled, held out to the side,
    /// then back. A lighter, more frequent personality beat than the rare
    /// Easter eggs (see `CharacterEngine`), not tied to any reaction.
    static let caneFlourish = AnimationClip(
        textures: pingpong(BillSpriteCatalog.cane),
        frameDuration: 0.13,
        loop: .once
    )

    /// The sheet's lean-and-arms-up beat spinning into a dynamic leap and a
    /// triumphant landing — a real celebration arc, not a 2-frame cheer
    /// replayed three times.
    static let celebrating = AnimationClip(
        textures: holdLast(BillSpriteCatalog.celebrating, extra: 2),
        frameDuration: 0.14,
        loop: .once
    )

    // MARK: - Rare Easter eggs (see BillState.rareEasterEggs — low-probability idle rolls only)

    /// A portal of rings widens, the ancient eye-and-bolt "true form" holds
    /// (ping-ponged once), then the portal closes back down — built from
    /// three sub-groups on the sheet (the ring frames, the true-form
    /// frames, and a single closing frame) that read as one continuous
    /// reveal when concatenated.
    static let powerSurge = AnimationClip(
        textures: BillSpriteCatalog.portalRing + pingpong(BillSpriteCatalog.powerSurge)
            + holdLast(BillSpriteCatalog.powerSurgeClose, extra: 6),
        frameDuration: 0.09,
        loop: .once
    )

    /// The zodiac dial spins through each of its six phases, then Bill
    /// manifests out of it — the full 8-frame sheet sequence, not a random
    /// 4-frame subset.
    static let zodiacVision = AnimationClip(
        textures: holdLast(BillSpriteCatalog.zodiac, extra: 3),
        frameDuration: 0.3,
        loop: .once
    )

    /// The full ring formation holds first (the actual dramatic reveal —
    /// see `BillSpriteCatalog.summonRitual`'s doc comment for why this
    /// replaced the old growth-sequence source), then the 3 alternate
    /// eye-render frames play through quickly as the ritual completes.
    static let summonRitual = AnimationClip(
        textures: Array(repeating: BillSpriteCatalog.summonRitual[0], count: 6) + Array(BillSpriteCatalog.summonRitual.dropFirst()),
        frameDuration: 0.25,
        loop: .once
    )

    /// The sheet's progressive "drained white" transformation — Bill
    /// spooked pale as a ghost, held, then settling back to color.
    static let ghostPale = AnimationClip(
        textures: holdLast(BillSpriteCatalog.ghost, extra: 5),
        frameDuration: 0.2,
        loop: .once
    )

    /// A monochrome, red-eyed "glitch" flicker — fast and jittery on
    /// purpose.
    static let glitchForm = AnimationClip(
        textures: pingpong(BillSpriteCatalog.glitch),
        frameDuration: 0.08,
        loop: .once
    )

    /// Pale hands, then a huge dark claw, reach for Bill — curated from two
    /// adjacent sheet groups (skipping their prop-only frames with no Bill
    /// in them) into one slow, ominous beat.
    static let shadowHands = AnimationClip(
        textures: holdLast(
            [
                BillSpriteCatalog.shadowB[0],
                BillSpriteCatalog.shadowA[0],
                BillSpriteCatalog.shadowA[3],
                BillSpriteCatalog.shadowB[2],
            ],
            extra: 4
        ),
        frameDuration: 0.3,
        loop: .once
    )

    /// The sheet's berserk buildup — mounting anger dissolving into a
    /// chaotic tangle of energy — held on the final chaos frame before
    /// settling back down.
    static let meltdown = AnimationClip(
        textures: holdLast(BillSpriteCatalog.meltdown, extra: 4),
        frameDuration: 0.15,
        loop: .once
    )

    // MARK: - Sustained conditions

    /// The sheet's actual lying-down pose, combined with a slow breathing
    /// bob and the existing Zzz particle overlay.
    static let sleeping = AnimationClip(
        textures: BillSpriteCatalog.sleeping,
        transform: [
            .body: [
                PoseKeyframe(duration: 1.6, offset: CGVector(dx: 0, dy: -2)),
                PoseKeyframe(duration: 1.6, offset: CGVector(dx: 0, dy: 0)),
            ],
        ],
        loop: .pingpong
    )

    /// A cane frame held out roughly horizontal reads as "gripping a
    /// controller" at Bill's small on-screen size — combined with a fast,
    /// excited rock rather than a vector controller bolted onto an idle
    /// pose.
    static let gaming = AnimationClip(
        textures: [BillSpriteCatalog.cane[5]],
        transform: [
            .body: [
                PoseKeyframe(duration: 0.3, rotation: -0.08),
                PoseKeyframe(duration: 0.3, rotation: 0.08),
            ],
        ],
        loop: .pingpong
    )

    /// The sheet's own crouched, hands-out pose, alternated at a brisk pace
    /// — reads as active hand movement over a keyboard-height surface.
    static let coding = AnimationClip(
        textures: BillSpriteCatalog.coding,
        frameDuration: 0.22,
        loop: .loop
    )

    /// The full worried → scorch-flash → fire → pale-aftermath arc,
    /// pingponged seamlessly forever (see `pingpongLoop` — this is a
    /// *continuous* state, unlike the one-shot beats above, so it must not
    /// use the manual `pingpong()`+`.once` pattern those use).
    static let heatingUp = AnimationClip(
        textures: pingpongLoop(BillSpriteCatalog.heating),
        frameDuration: 0.2,
        loop: .loop
    )

    /// The sheet's own lounge-chair-and-popcorn pose — a direct hit on
    /// "Charging: Bill relaxes" with zero need for a vector charger-cable
    /// prop. A gentle offset bob stands in for the "breathing" pulse this
    /// used to do via scale (1.03↔1.0) — Bill's on-screen size must never
    /// change (see `idle`'s bob and `AnimationClip.textureAction`'s doc
    /// comment for the same rule), so nothing here scales at all anymore.
    static let charging = AnimationClip(
        textures: BillSpriteCatalog.charging,
        transform: [
            .body: [
                PoseKeyframe(duration: 1.1, offset: CGVector(dx: 0, dy: 2)),
                PoseKeyframe(duration: 1.1, offset: CGVector(dx: 0, dy: 0)),
            ],
        ],
        loop: .pingpong
    )

    /// The sheet's channeling/spellcasting pose — continuous like
    /// coding/gaming (see `BillState.isContinuous`/`priority`, which already
    /// group this alongside them), pingponged forever rather than a
    /// one-shot beat.
    static let channeling = AnimationClip(
        textures: pingpongLoop(BillSpriteCatalog.channeling),
        frameDuration: 0.15,
        loop: .loop
    )

    /// The sheet's focused-concentration pose — unlike `channeling`, this
    /// is a brief personality beat (see `BillState.isContinuous`, which
    /// groups it with `smug`/`happy` rather than the sustained activity
    /// states), not a sustained activity loop.
    static let focused = AnimationClip(
        textures: pingpong(BillSpriteCatalog.focused),
        frameDuration: 0.2,
        loop: .once
    )

    // MARK: - Idle variety (short, sparse beats — not a continuous loop)

    @MainActor
    enum IdleVariant: CaseIterable {
        case shiftWeight
        case stretch
        case tiltCheck
        case curious

        var clip: AnimationClip {
            switch self {
            case .shiftWeight:
                // A different (but still resting) idle frame, held briefly —
                // reads as a subtle weight shift / glance rather than a
                // frozen statue.
                let frame = BillSpriteCatalog.idle[BillSpriteCatalog.idle.count / 2]
                return AnimationClip(textures: [frame], frameDuration: 0.9, loop: .once)
            case .stretch:
                // A small upward reach stands in for the old scale-pulse
                // (1.0↔1.06) — Bill's size must stay fixed (see `charging`'s
                // doc comment), so this is an offset, not a scale, change.
                return AnimationClip(
                    transform: [
                        .body: [
                            PoseKeyframe(duration: 0.35, offset: CGVector(dx: 0, dy: 6), timing: .easeOut),
                            PoseKeyframe(duration: 0.45, offset: CGVector(dx: 0, dy: 0), timing: .easeIn),
                        ],
                    ],
                    loop: .once
                )
            case .tiltCheck:
                return AnimationClip(
                    transform: [
                        .body: [
                            PoseKeyframe(duration: 0.4, rotation: 0.1),
                            PoseKeyframe(duration: 0.4, rotation: 0),
                        ],
                    ],
                    loop: .once
                )
            case .curious:
                // The sheet's chin-scratch pose — a light "hmm, what's
                // this?" beat, real sprite frames rather than a transform.
                return AnimationClip(
                    textures: BillSpriteCatalog.curious,
                    frameDuration: 0.25,
                    loop: .once
                )
            }
        }
    }
}
