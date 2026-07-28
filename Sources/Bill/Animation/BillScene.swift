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
        characterEngine.rig.root.position = CGPoint(x: size.width / 2, y: size.height * 0.42)
        addChild(characterEngine.rig.root)
    }
}
