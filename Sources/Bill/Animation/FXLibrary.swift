import SpriteKit

/// Particle effects layered over the rig. Built entirely in code (no .sks
/// particle files needed) and only ever attached to the scene while the
/// relevant state is active — never running as ambient/idle cost.
@MainActor
enum FXLibrary {
    static func steam() -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = Self.softCircleTexture
        emitter.particleBirthRate = 14
        emitter.particleLifetime = 1.1
        emitter.particleLifetimeRange = 0.4
        emitter.particlePositionRange = CGVector(dx: 14, dy: 4)
        emitter.particleSpeed = 26
        emitter.particleSpeedRange = 10
        emitter.emissionAngle = .pi / 2
        emitter.emissionAngleRange = .pi / 5
        emitter.particleAlpha = 0.5
        emitter.particleAlphaRange = 0.15
        emitter.particleAlphaSpeed = -0.5
        emitter.particleScale = 0.5
        emitter.particleScaleRange = 0.2
        emitter.particleScaleSpeed = 0.35
        emitter.particleColor = SKColor(white: 0.85, alpha: 1)
        emitter.particleColorBlendFactor = 1
        emitter.particleBlendMode = .alpha
        return emitter
    }

    static func sparkle() -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = Self.starTexture
        emitter.particleBirthRate = 18
        emitter.numParticlesToEmit = 0
        emitter.particleLifetime = 0.6
        emitter.particleLifetimeRange = 0.25
        emitter.particlePositionRange = CGVector(dx: 60, dy: 60)
        emitter.particleSpeed = 6
        emitter.particleAlpha = 0.9
        emitter.particleAlphaSpeed = -1.4
        emitter.particleScale = 0.35
        emitter.particleScaleRange = 0.2
        emitter.particleScaleSpeed = -0.2
        emitter.particleRotationSpeed = 2
        emitter.particleColor = SKColor(red: 1, green: 0.92, blue: 0.5, alpha: 1)
        emitter.particleColorBlendFactor = 1
        emitter.particleBlendMode = .add
        return emitter
    }

    static func zzz() -> SKLabelNode {
        let label = SKLabelNode(text: "Z z z")
        label.fontName = "Marker Felt"
        label.fontSize = 22
        label.fontColor = SKColor(white: 1, alpha: 0.85)
        label.horizontalAlignmentMode = .center
        return label
    }

    static func confetti() -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = Self.softCircleTexture
        emitter.particleBirthRate = 60
        emitter.numParticlesToEmit = 60
        emitter.particleLifetime = 1.4
        emitter.particleLifetimeRange = 0.6
        emitter.particlePositionRange = CGVector(dx: 90, dy: 4)
        emitter.particleSpeed = 140
        emitter.particleSpeedRange = 60
        emitter.emissionAngle = .pi / 2
        emitter.emissionAngleRange = .pi * 0.7
        emitter.yAcceleration = -220
        emitter.particleAlpha = 1
        emitter.particleAlphaSpeed = -0.6
        emitter.particleScale = 0.28
        emitter.particleScaleRange = 0.15
        emitter.particleRotationSpeed = 4
        emitter.particleColorSequence = SKKeyframeSequence(
            keyframeValues: [
                SKColor.systemYellow, SKColor.systemPink, SKColor.systemTeal, SKColor.systemPurple,
            ],
            times: [0, 0.33, 0.66, 1]
        )
        emitter.particleColorBlendFactor = 1
        emitter.particleBlendMode = .alpha
        return emitter
    }

    // MARK: - Tiny procedural textures (no bundled image assets needed)

    private static let softCircleTexture: SKTexture = {
        let size = CGSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            let colors = [NSColor.white.withAlphaComponent(0.9).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width / 2,
                options: []
            )
            return true
        }
        return SKTexture(image: image)
    }()

    private static let starTexture: SKTexture = {
        let size = CGSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let points = 4
            let outerRadius = rect.width / 2
            let innerRadius = outerRadius * 0.4
            for i in 0..<(points * 2) {
                let angle = CGFloat(i) * .pi / CGFloat(points)
                let radius = i % 2 == 0 ? outerRadius : innerRadius
                let point = CGPoint(x: center.x + radius * sin(angle), y: center.y + radius * cos(angle))
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            NSColor.white.setFill()
            path.fill()
            return true
        }
        return SKTexture(image: image)
    }()
}
