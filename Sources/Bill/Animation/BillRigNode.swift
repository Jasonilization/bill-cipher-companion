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
    let bodyNode: SKSpriteNode

    /// Bill's source frames are ~55-70px on their long axis; scaled up for
    /// on-screen presence while nearest-neighbor filtering (set in
    /// `BillSpriteCatalog`) keeps every pixel crisp — no blur, no
    /// anti-aliasing, exactly as the pixel-art requirement calls for.
    static let displayScale: CGFloat = 1.9

    static func build() -> BillRigNode {
        let root = SKNode()
        root.name = "billRoot"

        let body = SKSpriteNode(texture: BillSpriteCatalog.restTexture)
        body.setScale(displayScale)
        body.position = .zero
        root.addChild(body)

        let handAnchor = SKNode()
        handAnchor.position = CGPoint(x: body.size.width * 0.34, y: -body.size.height * 0.08)
        body.addChild(handAnchor)

        return BillRigNode(
            root: root,
            parts: [.body: body],
            homes: [.body: PartHome()],
            rightHandAnchor: handAnchor,
            bodyNode: body
        )
    }
}
