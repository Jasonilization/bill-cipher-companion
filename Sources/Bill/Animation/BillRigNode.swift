import SpriteKit

/// Bill's on-screen rig — a single pixel-art `SKSpriteNode` whose texture is
/// swapped per animation frame (see `BillSpriteCatalog` and
/// `Docs/SpriteAnimationCatalog.md`).
///
/// The default center `anchorPoint` is fine here specifically *because*
/// every exported frame shares one identical canvas size with the character
/// bottom-center-aligned within it (baked in at export time, not handled
/// here) — swapping textures never changes the node's pixel dimensions, so
/// there's nothing to snap. Before that fix, frames were tightly cropped to
/// their own individual bounding boxes, so a wide arms-out frame and a
/// narrow idle frame had different sizes/centers and the body visibly
/// jumped every time the texture swapped.
@MainActor
struct BillRigNode {
    let root: SKNode
    let parts: [BillPart: SKNode]
    let homes: [BillPart: PartHome]
    let rightHandAnchor: SKNode
    /// The overlay layer: labeled effect animations (slash arcs, dash
    /// trails, charge particles) composite ON TOP of the body here. Hidden
    /// while idle. nil never happens — every rig gets one.
    let fxNode: SKSpriteNode
    /// The display scale fx textures render at (effects ship at the same
    /// game-pixel density as the body, so the fx node scales by this too).
    let fxScale: CGFloat
    let bodyNode: SKSpriteNode

    /// Bill's source frames are ~55-70px on their long axis; scaled up for
    /// on-screen presence while nearest-neighbor filtering (set in
    /// `BillSpriteCatalog`) keeps every pixel crisp — no blur, no
    /// anti-aliasing, exactly as the pixel-art requirement calls for.
    /// Pack characters pass their own scale (see `CharacterDefinition`).
    static let displayScale: CGFloat = 1.9

    /// Builds the rig for Bill (default) or a pack character: same single
    /// body node + texture-swap design, just seeded from that character's
    /// first idle frame at their tuned display scale.
    static func build(
        catalog: CharacterSpriteCatalog? = nil,
        displayScale scale: CGFloat = displayScale
    ) -> BillRigNode {
        let root = SKNode()
        root.name = "characterRoot"

        let restTexture = catalog?.restTexture ?? BillSpriteCatalog.restTexture
        let body = SKSpriteNode(texture: restTexture)
        body.setScale(scale)
        body.position = .zero
        root.addChild(body)

        // The effect overlay: same anchor/position as the body, above it.
        // Hidden until a clip's matching fx family plays; per-frame
        // resizing (resize: true) is safe here — effects never mirror.
        let fx = SKSpriteNode()
        fx.isHidden = true
        fx.zPosition = body.zPosition + 1
        fx.position = body.position
        root.addChild(fx)

        let handAnchor = SKNode()
        handAnchor.position = CGPoint(x: body.size.width * 0.34, y: -body.size.height * 0.08)
        body.addChild(handAnchor)

        return BillRigNode(
            root: root,
            parts: [.body: body],
            homes: [.body: PartHome()],
            rightHandAnchor: handAnchor,
            fxNode: fx,
            fxScale: scale,
            bodyNode: body
        )
    }
}
