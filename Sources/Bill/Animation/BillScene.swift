import SpriteKit

/// Thin SpriteKit host for Bill's rig. Owns no behavior/animation logic
/// itself — `CharacterEngine`/`BillStateMachine` do all of that — this just
/// adds the already-built node tree to the scene graph.
@MainActor
final class BillScene: SKScene {
    private let characterEngine: CharacterEngine

    init(size: CGSize, characterEngine: CharacterEngine) {
        self.characterEngine = characterEngine
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMove(to view: SKView) {
        // Anchored near the bottom of the canvas (rather than centered) so
        // the extra height above his hat is free for the bark speech bubble.
        characterEngine.rig.root.position = CGPoint(x: size.width / 2, y: 110)
        addChild(characterEngine.rig.root)
    }
}
