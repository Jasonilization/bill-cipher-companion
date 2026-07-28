import SpriteKit

enum ClipLoopMode: Sendable {
    case once
    case loop
    case pingpong
}

/// A part's rest transform in its parent's coordinate space. Clip keyframes
/// are expressed relative to this, so a clip only ever needs to describe
/// "how far from home", never worry about each part's particular resting
/// angle (arms/legs rest at a splayed angle, not zero).
struct PartHome: Sendable {
    var offset: CGVector = .zero
    var rotation: CGFloat = 0
}

/// One target pose for a part, relative to its home transform, held for
/// `duration` seconds after interpolating from wherever the part currently is.
///
/// `duration` is declared first (and is the only required field) so every
/// call site below can consistently write arguments as
/// `(duration:, offset:, rotation:, scale:, timing:)` — Swift requires
/// labeled arguments to appear in declaration order, so keeping one fixed
/// order here avoids call-site ordering mistakes across dozens of clips.
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

/// A declarative, data-only animation: for each part that moves, an ordered
/// list of keyframes relative to that part's home transform. Parts not
/// mentioned simply stay wherever they last were (typically home, since
/// clips return parts home before they end). Turning this into real
/// `SKAction`s happens in `buildActions`.
struct AnimationClip: Sendable {
    var tracks: [BillPart: [PoseKeyframe]]
    var loop: ClipLoopMode = .once

    var singlePassDuration: TimeInterval {
        tracks.values.map { $0.reduce(0) { $0 + $1.duration } }.max() ?? 0
    }

    private func action(for keyframes: [PoseKeyframe], home: PartHome) -> SKAction {
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

    /// Builds the full set of per-node actions for this clip, keyed by part,
    /// already wrapped for this clip's loop mode.
    func buildActions(homes: [BillPart: PartHome]) -> [BillPart: SKAction] {
        var result: [BillPart: SKAction] = [:]
        for (part, keyframes) in tracks {
            guard !keyframes.isEmpty else { continue }
            let home = homes[part] ?? PartHome()
            let forward = action(for: keyframes, home: home)
            switch loop {
            case .once:
                result[part] = forward
            case .loop:
                result[part] = SKAction.repeatForever(forward)
            case .pingpong:
                var backKeyframes = Array(keyframes.dropLast().reversed())
                backKeyframes.append(PoseKeyframe(duration: keyframes.last?.duration ?? 0.3, timing: keyframes.last?.timing ?? .easeInEaseOut))
                let backward = action(for: backKeyframes, home: home)
                result[part] = SKAction.repeatForever(SKAction.sequence([forward, backward]))
            }
        }
        return result
    }
}
