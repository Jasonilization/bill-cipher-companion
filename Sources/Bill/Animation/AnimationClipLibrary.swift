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
/// for what's on the sheet, the full frame-by-frame analysis, and why each
/// clip below uses what it uses. No procedural vector props are attached to
/// any state; the sprite frames themselves carry the "holding something" or
/// "working" read (e.g. coding's crouched hand pose, gaming's raised-object
/// grip) rather than a bolted-on vector laptop/controller.
///
/// A hard rule that fixes the clipping/snapping bug from the first sprite
/// pass: every non-continuous (`isContinuous == false`) clip **must** use
/// `loop: .once` — `BillStateMachine.runClip` only schedules the
/// auto-settle-back-to-idle timer for `.once` clips, so a one-shot beat
/// declared with `.loop`/`.pingpong` would play forever and never return to
/// idle on its own (this was a real bug in the first pass: `celebrating`
/// was `.pingpong` while `isContinuous == false`, so it never settled).
/// Clips that want a multi-cycle feel repeat their texture array manually
/// instead of relying on the loop mode.
@MainActor
enum AnimationClipLibrary {

    /// Builds a "there and back" (optionally multi-cycle) frame sequence
    /// from a base set without duplicating the turnaround frame — naively
    /// appending `frames.reversed()` repeats the last frame twice in a row,
    /// a visible one-frame stutter right at the point the motion reverses.
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
        case .powerSurge: return powerSurge
        case .zodiacVision: return zodiacVision
        case .summonRitual: return summonRitual
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
        case .happy, .smug: return .sparkle
        case .powerSurge, .zodiacVision, .summonRitual: return .sparkle
        default: return nil
        }
    }

    // MARK: - Ambient rest

    static let idle = AnimationClip()

    // MARK: - Locomotion

    static let walking = AnimationClip(
        textures: BillSpriteCatalog.walk,
        frameDuration: 0.13,
        loop: .loop
    )

    // MARK: - Conversational

    /// The sheet's clean 5-frame wave/greeting arc — a big genuine grin and
    /// a full arm sweep overhead reads far better as "gesturing while
    /// talking" than a procedural bob ever did.
    static let talking = AnimationClip(
        textures: BillSpriteCatalog.greeting,
        frameDuration: 0.1,
        loop: .pingpong
    )

    /// The sheet's dedicated hand-to-head pondering sequence.
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

    static let annoyed = AnimationClip(
        textures: BillSpriteCatalog.annoyed,
        frameDuration: 0.2,
        loop: .once
    )

    static let surprised = AnimationClip(
        textures: BillSpriteCatalog.surprised,
        frameDuration: 0.5,
        loop: .once
    )

    static let confused = AnimationClip(
        textures: BillSpriteCatalog.confused,
        frameDuration: 0.7,
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

    /// A confident flex — held, with a tiny wobble, not looped forever
    /// (celebrating's original bug: see the type-level doc comment).
    static let smug = AnimationClip(
        textures: pingpong(BillSpriteCatalog.smug),
        frameDuration: 0.35,
        loop: .once
    )

    /// Several full arms-up cheer cycles, then settle — *not* a literal
    /// `.pingpong` loop (see the type-level doc comment for why that was a
    /// real bug: a non-continuous state declared with a repeating loop mode
    /// never fires its auto-settle timer and gets stuck forever).
    static let celebrating = AnimationClip(
        textures: pingpong(BillSpriteCatalog.happy, cycles: 3),
        frameDuration: 0.15,
        loop: .once
    )

    // MARK: - Rare Easter eggs (see BillState.rareEasterEggs — low-probability idle rolls only)

    /// The sheet's dramatic many-eyed energy-surge frames. Deliberately
    /// intense; gated to a rare random roll rather than any normal trigger.
    static let powerSurge = AnimationClip(
        textures: pingpong(BillSpriteCatalog.powerSurge),
        frameDuration: 0.12,
        loop: .once
    )

    /// The zodiac-wheel "prophecy" dial fading in and back out.
    static let zodiacVision = AnimationClip(
        textures: pingpong(BillSpriteCatalog.zodiac),
        frameDuration: 0.35,
        loop: .once
    )

    /// The ritual-circle summon — a single striking image, held.
    static let summonRitual = AnimationClip(
        textures: BillSpriteCatalog.summon,
        frameDuration: 2.4,
        loop: .once
    )

    // MARK: - Sustained conditions

    /// The sheet's actual lying-down pose, not a borrowed dazed frame —
    /// combined with a slow breathing bob and the existing Zzz FX overlay.
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

    /// A single frame lifted from the walk cycle (arm raised, gripping the
    /// woven object) read as "holding a controller" — combined with a fast,
    /// excited rock rather than a vector controller bolted onto an idle pose.
    static let gaming = AnimationClip(
        textures: [BillSpriteCatalog.walk[1]],
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

    static let heatingUp = AnimationClip(
        textures: BillSpriteCatalog.heating,
        frameDuration: 0.25,
        loop: .pingpong
    )

    /// The sheet's own lounge-chair-and-popcorn pose — a direct hit on
    /// "Charging: Bill relaxes" with zero need for a vector charger-cable
    /// prop.
    static let charging = AnimationClip(
        textures: BillSpriteCatalog.charging,
        transform: [
            .body: [
                PoseKeyframe(duration: 1.1, scale: 1.03),
                PoseKeyframe(duration: 1.1, scale: 1.0),
            ],
        ],
        loop: .pingpong
    )

    // MARK: - Idle variety (short, sparse beats — not a continuous loop)

    @MainActor
    enum IdleVariant: CaseIterable {
        case shiftWeight
        case stretch
        case tiltCheck

        var clip: AnimationClip {
            switch self {
            case .shiftWeight:
                // A different (but still resting) idle frame, held briefly —
                // reads as a subtle weight shift / glance rather than a
                // frozen statue.
                let frame = BillSpriteCatalog.idle[BillSpriteCatalog.idle.count / 2]
                return AnimationClip(textures: [frame], frameDuration: 0.9, loop: .once)
            case .stretch:
                return AnimationClip(
                    transform: [
                        .body: [
                            PoseKeyframe(duration: 0.35, scale: 1.06, timing: .easeOut),
                            PoseKeyframe(duration: 0.45, scale: 1.0, timing: .easeIn),
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
            }
        }
    }
}
