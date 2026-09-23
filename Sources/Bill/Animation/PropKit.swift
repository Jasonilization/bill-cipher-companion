import SpriteKit

/// Props Bill can hold. Structural, not animated-per-part: each prop is a
/// small node tree attached directly to the right-hand anchor so it
/// automatically follows arm gestures without its own keyframe track.
enum BillProp: String, Sendable {
    case none
    case cane
    case laptop
    case controller
    case thermometer
    case chargerCable

    @MainActor
    func makeNode() -> SKNode? {
        switch self {
        case .none:
            return nil
        case .cane:
            return PropKit.cane()
        case .laptop:
            return PropKit.laptop()
        case .controller:
            return PropKit.controller()
        case .thermometer:
            return PropKit.thermometer()
        case .chargerCable:
            return PropKit.chargerCable()
        }
    }
}

@MainActor
enum PropKit {
    static func cane() -> SKNode {
        // The hand anchor is a child of the arm's own rotating container, so
        // local +Y here would retrace back over the arm itself (same
        // direction, same length) and disappear underneath it. Extending
        // along -Y continues *past* the hand, in the direction the limb
        // already points, which is what actually reads as "held cane".
        let container = SKNode()
        let shaft = CGMutablePath()
        shaft.move(to: .zero)
        shaft.addLine(to: CGPoint(x: 0, y: -46))
        let shaftNode = SKShapeNode(path: shaft)
        shaftNode.strokeColor = BillPalette.black
        shaftNode.lineWidth = 4
        shaftNode.lineCap = .round
        container.addChild(shaftNode)

        let handlePath = CGMutablePath()
        handlePath.addArc(center: CGPoint(x: -8, y: -46), radius: 10, startAngle: 0, endAngle: .pi, clockwise: false)
        let handle = SKShapeNode(path: handlePath)
        handle.strokeColor = BillPalette.black
        handle.lineWidth = 4
        handle.lineCap = .round
        container.addChild(handle)
        return container
    }

    static func laptop() -> SKNode {
        let container = SKNode()
        let base = SKShapeNode(rectOf: CGSize(width: 40, height: 4), cornerRadius: 1.5)
        base.fillColor = BillPalette.black
        base.strokeColor = .clear
        base.position = CGPoint(x: 0, y: 4)
        container.addChild(base)

        let screen = SKShapeNode(rectOf: CGSize(width: 34, height: 24), cornerRadius: 2)
        screen.fillColor = SKColor(white: 0.12, alpha: 1)
        screen.strokeColor = BillPalette.black
        screen.lineWidth = 2
        screen.position = CGPoint(x: 0, y: 20)
        container.addChild(screen)

        let glow = SKShapeNode(rectOf: CGSize(width: 28, height: 18), cornerRadius: 1)
        glow.fillColor = SKColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 0.85)
        glow.strokeColor = .clear
        glow.position = CGPoint(x: 0, y: 20)
        container.addChild(glow)

        container.position = CGPoint(x: -14, y: 6)
        return container
    }

    static func controller() -> SKNode {
        let container = SKNode()
        let body = SKShapeNode(rectOf: CGSize(width: 42, height: 22), cornerRadius: 10)
        body.fillColor = SKColor(white: 0.15, alpha: 1)
        body.strokeColor = BillPalette.black
        body.lineWidth = 2
        container.addChild(body)

        for dx: CGFloat in [-10, 10] {
            let stick = SKShapeNode(circleOfRadius: 5)
            stick.fillColor = SKColor(white: 0.3, alpha: 1)
            stick.strokeColor = .clear
            stick.position = CGPoint(x: dx, y: 2)
            container.addChild(stick)
        }
        return container
    }

    static func thermometer() -> SKNode {
        let container = SKNode()
        let tube = SKShapeNode(rectOf: CGSize(width: 8, height: 34), cornerRadius: 4)
        tube.fillColor = SKColor(white: 0.9, alpha: 1)
        tube.strokeColor = BillPalette.black
        tube.lineWidth = 1.5
        tube.position = CGPoint(x: 0, y: 20)
        container.addChild(tube)

        let bulb = SKShapeNode(circleOfRadius: 7)
        bulb.fillColor = SKColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        bulb.strokeColor = BillPalette.black
        bulb.lineWidth = 1.5
        bulb.position = CGPoint(x: 0, y: 2)
        container.addChild(bulb)
        return container
    }

    static func chargerCable() -> SKNode {
        let container = SKNode()
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: 10, y: 50), control1: CGPoint(x: -14, y: 15), control2: CGPoint(x: 24, y: 30))
        let cable = SKShapeNode(path: path)
        cable.strokeColor = SKColor(white: 0.85, alpha: 1)
        cable.lineWidth = 4
        cable.lineCap = .round
        container.addChild(cable)

        let plug = SKShapeNode(rectOf: CGSize(width: 10, height: 14), cornerRadius: 2)
        plug.fillColor = SKColor(white: 0.85, alpha: 1)
        plug.strokeColor = .clear
        plug.position = CGPoint(x: 10, y: 50)
        container.addChild(plug)
        return container
    }
}
