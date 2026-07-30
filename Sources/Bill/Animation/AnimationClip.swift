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
    var scale: CGFloat = 1
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
            let scale = SKAction.scale(to: kf.scale, duration: kf.duration)
            move.timingMode = kf.timing
            rotate.timingMode = kf.timing
            scale.timingMode = kf.timing
            return SKAction.group([move, rotate, scale])
        }
        return SKAction.sequence(steps)
    }

    private func textureAction() -> SKAction? {
        guard !textures.isEmpty else { return nil }
        if textures.count == 1 {
            return SKAction.setTexture(textures[0], resize: true)
        }
        return SKAction.animate(with: textures, timePerFrame: frameDuration, resize: true, restore: false)
    }

    /// Builds the full set of per-part actions for this clip, keyed by part.
    func buildActions(homes: [BillPart: PartHome]) -> [BillPart: SKAction] {
        var result: [BillPart: SKAction] = [:]
        var bodyActions: [SKAction] = []

        if let texAction = textureAction() {
            switch loop {
            case .once:
                bodyActions.append(texAction)
            case .loop:
                bodyActions.append(SKAction.repeatForever(texAction))
            case .pingpong:
                let reversed = SKAction.animate(with: Array(textures.reversed()), timePerFrame: frameDuration, resize: true, restore: false)
                bodyActions.append(SKAction.repeatForever(SKAction.sequence([texAction, reversed])))
            }
        }

        for (part, keyframes) in transform {
            guard !keyframes.isEmpty else { continue }
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
