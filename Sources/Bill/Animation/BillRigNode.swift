import SpriteKit

/// Builds Bill's SpriteKit node tree once and hands back everything the
/// state machine / character engine need: per-part nodes to animate, their
/// home transforms (so clips can express relative targets), and an anchor
/// node for prop attachment (right hand).
@MainActor
struct BillRigNode {
    let root: SKNode
    let parts: [BillPart: SKNode]
    let homes: [BillPart: PartHome]
    let rightHandAnchor: SKNode
    let eyeNode: SKShapeNode
    let pupilNode: SKShapeNode
    let hatNode: SKNode

    static func build() -> BillRigNode {
        let root = SKNode()
        root.name = "billRoot"

        var parts: [BillPart: SKNode] = [:]
        var homes: [BillPart: PartHome] = [:]

        // MARK: Body
        let bodyPath = CGMutablePath()
        bodyPath.move(to: CGPoint(x: 0, y: 52))
        bodyPath.addLine(to: CGPoint(x: 46, y: -36))
        bodyPath.addLine(to: CGPoint(x: -46, y: -36))
        bodyPath.closeSubpath()
        let body = SKShapeNode(path: bodyPath)
        body.fillColor = BillPalette.bodyYellow
        body.strokeColor = BillPalette.bodyYellowDark
        body.lineWidth = 3
        body.name = "body"
        body.zPosition = 0
        root.addChild(body)
        parts[.body] = body
        homes[.body] = PartHome()

        // MARK: Legs (slightly behind the body, splayed at rest)
        let leftLegHome = PartHome(offset: CGVector(dx: -22, dy: -36), rotation: -0.18)
        let (leftLeg, _) = Self.makeLimb(length: 36, width: 12, limbColor: BillPalette.black, tipRadius: 8, tipColor: BillPalette.black)
        leftLeg.position = CGPoint(x: leftLegHome.offset.dx, y: leftLegHome.offset.dy)
        leftLeg.zRotation = leftLegHome.rotation
        leftLeg.zPosition = -1
        root.addChild(leftLeg)
        parts[.leftLeg] = leftLeg
        homes[.leftLeg] = leftLegHome

        let rightLegHome = PartHome(offset: CGVector(dx: 22, dy: -36), rotation: 0.18)
        let (rightLeg, _) = Self.makeLimb(length: 36, width: 12, limbColor: BillPalette.black, tipRadius: 8, tipColor: BillPalette.black)
        rightLeg.position = CGPoint(x: rightLegHome.offset.dx, y: rightLegHome.offset.dy)
        rightLeg.zRotation = rightLegHome.rotation
        rightLeg.zPosition = -1
        root.addChild(rightLeg)
        parts[.rightLeg] = rightLeg
        homes[.rightLeg] = rightLegHome

        // MARK: Arms
        let leftArmHome = PartHome(offset: CGVector(dx: -44, dy: -4), rotation: -0.45)
        let (leftArm, _) = Self.makeLimb(length: 48, width: 13, limbColor: BillPalette.black, tipRadius: 9, tipColor: BillPalette.gloveWhite)
        leftArm.position = CGPoint(x: leftArmHome.offset.dx, y: leftArmHome.offset.dy)
        leftArm.zRotation = leftArmHome.rotation
        leftArm.zPosition = 1
        root.addChild(leftArm)
        parts[.leftArm] = leftArm
        homes[.leftArm] = leftArmHome

        let rightArmHome = PartHome(offset: CGVector(dx: 44, dy: -4), rotation: 0.45)
        let (rightArm, rightHandAnchor) = Self.makeLimb(length: 48, width: 13, limbColor: BillPalette.black, tipRadius: 9, tipColor: BillPalette.gloveWhite)
        rightArm.position = CGPoint(x: rightArmHome.offset.dx, y: rightArmHome.offset.dy)
        rightArm.zRotation = rightArmHome.rotation
        rightArm.zPosition = 1
        root.addChild(rightArm)
        parts[.rightArm] = rightArm
        homes[.rightArm] = rightArmHome

        // MARK: Eye
        let eyeHome = PartHome(offset: CGVector(dx: 0, dy: 6))
        let eye = SKShapeNode(circleOfRadius: 24)
        eye.fillColor = BillPalette.eyeWhite
        eye.strokeColor = BillPalette.bodyYellowDark
        eye.lineWidth = 2
        eye.position = CGPoint(x: eyeHome.offset.dx, y: eyeHome.offset.dy)
        eye.zPosition = 2
        root.addChild(eye)
        parts[.eye] = eye
        homes[.eye] = eyeHome

        let pupil = SKShapeNode(circleOfRadius: 10)
        pupil.fillColor = BillPalette.pupilBlack
        pupil.strokeColor = .clear
        pupil.position = .zero
        pupil.zPosition = 3
        eye.addChild(pupil)
        parts[.pupil] = pupil
        homes[.pupil] = PartHome()

        // MARK: Bow tie
        let bowtieHome = PartHome(offset: CGVector(dx: 0, dy: -24))
        let bowtie = Self.makeBowtie()
        bowtie.position = CGPoint(x: bowtieHome.offset.dx, y: bowtieHome.offset.dy)
        bowtie.zPosition = 2
        root.addChild(bowtie)
        parts[.bowtie] = bowtie
        homes[.bowtie] = bowtieHome

        // MARK: Hat
        let hatHome = PartHome(offset: CGVector(dx: 0, dy: 52))
        let hat = Self.makeHat()
        hat.position = CGPoint(x: hatHome.offset.dx, y: hatHome.offset.dy)
        hat.zPosition = 2
        root.addChild(hat)
        parts[.hat] = hat
        homes[.hat] = hatHome

        return BillRigNode(
            root: root,
            parts: parts,
            homes: homes,
            rightHandAnchor: rightHandAnchor,
            eyeNode: eye,
            pupilNode: pupil,
            hatNode: hat
        )
    }

    /// A limb: a rounded capsule from the anchor down to a rounded tip
    /// (foot/hand). Returns the container (positioned/rotated as a whole)
    /// and the tip node (used as the prop-attachment anchor for the hand).
    private static func makeLimb(length: CGFloat, width: CGFloat, limbColor: SKColor, tipRadius: CGFloat, tipColor: SKColor) -> (SKNode, SKNode) {
        let container = SKNode()
        let path = CGMutablePath()
        path.addRoundedRect(
            in: CGRect(x: -width / 2, y: -length, width: width, height: length),
            cornerWidth: width / 2,
            cornerHeight: width / 2
        )
        let limb = SKShapeNode(path: path)
        limb.fillColor = limbColor
        limb.strokeColor = .clear
        container.addChild(limb)

        let tip = SKShapeNode(circleOfRadius: tipRadius)
        tip.fillColor = tipColor
        tip.strokeColor = .clear
        tip.position = CGPoint(x: 0, y: -length)
        container.addChild(tip)

        return (container, tip)
    }

    private static func makeBowtie() -> SKNode {
        let container = SKNode()
        func wing(flip: CGFloat) -> SKShapeNode {
            let path = CGMutablePath()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: flip * 18, y: 9))
            path.addLine(to: CGPoint(x: flip * 18, y: -9))
            path.closeSubpath()
            let node = SKShapeNode(path: path)
            node.fillColor = BillPalette.black
            node.strokeColor = .clear
            return node
        }
        container.addChild(wing(flip: 1))
        container.addChild(wing(flip: -1))
        let knot = SKShapeNode(circleOfRadius: 4.5)
        knot.fillColor = BillPalette.black
        knot.strokeColor = .clear
        container.addChild(knot)
        return container
    }

    private static func makeHat() -> SKNode {
        let container = SKNode()
        let brimPath = CGMutablePath()
        brimPath.addRoundedRect(
            in: CGRect(x: -36, y: -4, width: 72, height: 10),
            cornerWidth: 5,
            cornerHeight: 5
        )
        let brim = SKShapeNode(path: brimPath)
        brim.fillColor = BillPalette.black
        brim.strokeColor = .clear
        container.addChild(brim)

        let crownPath = CGMutablePath()
        crownPath.move(to: CGPoint(x: -19, y: 2))
        crownPath.addLine(to: CGPoint(x: -15, y: 46))
        crownPath.addLine(to: CGPoint(x: 15, y: 46))
        crownPath.addLine(to: CGPoint(x: 19, y: 2))
        crownPath.closeSubpath()
        let crown = SKShapeNode(path: crownPath)
        crown.fillColor = BillPalette.black
        crown.strokeColor = .clear
        container.addChild(crown)

        return container
    }
}
