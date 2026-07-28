import SpriteKit

/// Builds the little speech-bubble node used to show a bark line above
/// Bill's head. Pure presentation — `BillStateMachine` owns the timing.
@MainActor
enum BarkBubble {
    static func makeNode(text: String, maxWidth: CGFloat) -> SKNode {
        let label = SKLabelNode(text: text)
        label.fontName = "HelveticaNeue-Medium"
        label.fontSize = 13
        label.fontColor = SKColor(white: 0.08, alpha: 1)
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = maxWidth - 24
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.lineBreakMode = .byWordWrapping

        let textSize = label.frame.size
        let bubbleSize = CGSize(
            width: min(maxWidth, textSize.width + 24),
            height: textSize.height + 20
        )

        let container = SKNode()

        let bubble = SKShapeNode(rectOf: bubbleSize, cornerRadius: 14)
        bubble.fillColor = SKColor(white: 0.98, alpha: 0.96)
        bubble.strokeColor = SKColor(white: 0, alpha: 0.12)
        bubble.lineWidth = 1
        container.addChild(bubble)
        container.addChild(label)

        let tailPath = CGMutablePath()
        tailPath.move(to: CGPoint(x: -7, y: -bubbleSize.height / 2))
        tailPath.addLine(to: CGPoint(x: 7, y: -bubbleSize.height / 2))
        tailPath.addLine(to: CGPoint(x: 0, y: -bubbleSize.height / 2 - 9))
        tailPath.closeSubpath()
        let tail = SKShapeNode(path: tailPath)
        tail.fillColor = SKColor(white: 0.98, alpha: 0.96)
        tail.strokeColor = .clear
        container.addChild(tail)

        return container
    }
}
