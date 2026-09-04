import SpriteKit

enum ClipLoopMode: Sendable {
    case once
    case loop
    case pingpong
}

/// A part's rest transform in its parent's coordinate space.
struct PartHome: Sendable {
    var offset: CGVector = .zero
    var rotation: CGFloat = 0
}

/// One target transform, relative to a part's home, held for `duration`
/// seconds. Used for the *procedural* half of a clip (bob/tilt/scale) —
/// the pixel-art half is `AnimationClip.textures`.
struct PoseKeyframe: Sendable {
    var duration: TimeInterval
    var offset: CGVector = .zero
    var rotation: CGFloat = 0
    /// `nil` (the default) means "don't touch scale" — distinct from `1`,
    /// which would explicitly force it. Every clip used to implicitly force
    /// `1` on every keyframe (the old non-optional default), which silently
    /// undid any horizontal-flip `xScale` set externally (wander's
    /// walking-direction mirror) every single frame of any clip with a
    /// transform track — walking's own bob included, since it fired every
    /// 0.22s. `nil` lets a clip that doesn't care about scale leave
    /// whatever's already there alone.
    var scale: CGFloat?
    var timing: SKActionTimingMode = .easeInEaseOut

    static func hold(_ duration: TimeInterval) -> PoseKeyframe {
        PoseKeyframe(duration: duration)
    }
}

/// A declarative, data-only animation with two independent tracks that can
/// run together on the body node:
///
/// - `textures`: the pixel-art frame sequence itself (e.g. the 4-frame walk
///   cycle). Empty when a state has no dedicated sprite sequence.
/// - `transform`: a procedural bob/tilt/scale layered on top (e.g. "talking"
///   has no dedicated frames at all — it's pure transform on the idle
///   texture; "walking" is pure texture sequence; nothing stops a future
///   clip from using both at once).
///
/// This is the same clip/keyframe shape the earlier procedural rig used,
/// extended with a texture track — `BillStateMachine` and everything above
/// it never needed to know the difference.
struct AnimationClip {
    var textures: [SKTexture] = []
    var frameDuration: TimeInterval = 0.12
    var transform: [BillPart: [PoseKeyframe]] = [:]
    var loop: ClipLoopMode = .once

    var singlePassDuration: TimeInterval {
        let textureDuration = textures.isEmpty ? 0 : Double(textures.count) * frameDuration
        let transformDuration = transform.values.map { $0.reduce(0) { $0 + $1.duration } }.max() ?? 0
        return max(textureDuration, transformDuration)
    }

    private func transformAction(for keyframes: [PoseKeyframe], home: PartHome) -> SKAction {
        let steps = keyframes.map { kf -> SKAction in
            let point = CGPoint(x: home.offset.dx + kf.offset.dx, y: home.offset.dy + kf.offset.dy)
            let move = SKAction.move(to: point, duration: kf.duration)
            let rotate = SKAction.rotate(toAngle: home.rotation + kf.rotation, duration: kf.duration, shortestUnitArc: true)
            move.timingMode = kf.timing
            rotate.timingMode = kf.timing
            var actions: [SKAction] = [move, rotate]
            if let targetScale = kf.scale {
                let scale = SKAction.scale(to: targetScale, duration: kf.duration)
                scale.timingMode = kf.timing
                actions.append(scale)
            }
            return SKAction.group(actions)
        }
        return SKAction.sequence(steps)
    }

    private func textureAction() -> SKAction? {
        guard !textures.isEmpty else { return nil }
        // `resize: false` deliberately, not `true` — every frame across
        // every group shares one identical baked canvas size (that's the
        // whole point of the shared-canvas anti-clipping fix), so resizing
        // per-frame was never actually necessary. It was also actively
        // harmful: `resize: true` re-derives the node's rendered size from
        // each incoming texture on every single frame swap, which stomps
        // any externally-set `xScale` sign back to positive — silently
        // undoing wander's horizontal direction-flip within one frame of
        // the walk cycle starting (confirmed by comparing screenshots of a
        // leftward vs. a rightward wander leg: identical silhouette in
        // both, which a working flip would never produce).
        if textures.count == 1 {
            return SKAction.setTexture(textures[0], resize: false)
        }
        return SKAction.animate(with: textures, timePerFrame: frameDuration, resize: false, restore: false)
    }

    /// Builds the full set of per-part actions for this clip, keyed by part.
    func buildActions(homes: [BillPart: PartHome]) -> [BillPart: SKAction] {
        var result: [BillPart: SKAction] = [:]
        var bodyActions: [SKAction] = []

        if let texAction = textureAction() {
            // A one-texture clip has no sequence to cycle — `textureAction()`
            // returns `setTexture`, which is *instantaneous*.
            //
            // Wrapping an instantaneous action in `repeatForever` is a hard
            // hang, not a waste: SpriteKit runs the inner action as many times
            // as fit in the elapsed frame, and with a zero-length action that
            // never terminates. The main thread pins at 100% inside
            // `SKCRepeat`/`SKCAnimate` and the whole app stops responding —
            // observed live, and diagnosed from a `sample` of the frozen
            // process. Two of the new roaming clips (`rising`, `hangingIdle`)
            // hit exactly this.
            //
            // So a single-frame clip sets its texture once and lets the
            // transform track do any looping; there is nothing else it could
            // meaningfully animate.
            let isInstantaneous = textures.count == 1
            switch loop {
            case .once:
                bodyActions.append(texAction)
            case .loop:
                bodyActions.append(isInstantaneous ? texAction : SKAction.repeatForever(texAction))
            case .pingpong:
                if isInstantaneous {
                    bodyActions.append(texAction)
                } else {
                    let reversed = SKAction.animate(with: Array(textures.reversed()), timePerFrame: frameDuration, resize: false, restore: false)
                    bodyActions.append(SKAction.repeatForever(SKAction.sequence([texAction, reversed])))
                }
            }
        }

        for (part, keyframes) in transform {
            guard !keyframes.isEmpty else { continue }
            // Same trap as the texture track above: a keyframe set that adds
            // up to no time at all must never be repeated forever.
            guard keyframes.reduce(0, { $0 + $1.duration }) > 0 else { continue }
            let home = homes[part] ?? PartHome()
            let forward = transformAction(for: keyframes, home: home)
            let wrapped: SKAction
            switch loop {
            case .once:
                wrapped = forward
            case .loop:
                wrapped = SKAction.repeatForever(forward)
            case .pingpong:
                var backKeyframes = Array(keyframes.dropLast().reversed())
                backKeyframes.append(PoseKeyframe(duration: keyframes.last?.duration ?? 0.3, timing: keyframes.last?.timing ?? .easeInEaseOut))
                let backward = transformAction(for: backKeyframes, home: home)
                wrapped = SKAction.repeatForever(SKAction.sequence([forward, backward]))
            }
            if part == .body {
                bodyActions.append(wrapped)
            } else {
                result[part] = wrapped
            }
        }

        if !bodyActions.isEmpty {
            result[.body] = bodyActions.count == 1 ? bodyActions[0] : SKAction.group(bodyActions)
        }

        return result
    }
}
