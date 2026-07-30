import AppKit
import SpriteKit

/// Builds Bill's speech bubble as a genuinely pixel-art bitmap: background,
/// stepped/blocky border, and text are all rendered together into one
/// small, non-antialiased image, then displayed with nearest-neighbor
/// scaling — the same technique `BillSpriteCatalog` uses for Bill himself.
/// The bubble reads as part of the same pixel-art object rather than a
/// smooth modern rounded-rect popover bolted on top of him.
@MainActor
enum BarkBubble {
    /// How much the low-res bitmap gets blown up on screen — kept as a
    /// whole-ish number so pixels land on pixel boundaries and stay crisp.
    private static let pixelScale: CGFloat = 2
    private static let font = NSFont(name: "Monaco", size: 8) ?? NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
    private static let cornerStep: CGFloat = 3
    /// In bubble-pixel units (before `pixelScale`) — chosen so a typical
    /// bark sentence wraps to 3-4 lines of real words, not one word per
    /// line. `maxWidth` (in final on-screen points) is intentionally not
    /// used for this: dividing a points-space budget by `pixelScale` was
    /// the original bug, producing a column too narrow for the font.
    private static let maxTextWidth: CGFloat = 130

    static func makeNode(text: String, maxWidth: CGFloat) -> SKNode {
        let (lines, textSize) = wrapText(text.uppercased(), maxWidth: maxTextWidth)

        let paddingX: CGFloat = 6
        let paddingY: CGFloat = 5
        let tailHeight: CGFloat = 6
        let bodyWidth = ceil(textSize.width) + paddingX * 2
        let bodyHeight = ceil(textSize.height) + paddingY * 2
        let imageSize = CGSize(width: bodyWidth, height: bodyHeight + tailHeight)

        let image = NSImage(size: imageSize, flipped: false) { [self] _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(false)
            ctx.setAllowsAntialiasing(false)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSmoothing(false)
            ctx.interpolationQuality = .none

            let bodyRect = CGRect(x: 0, y: tailHeight, width: bodyWidth, height: bodyHeight)

            ctx.addPath(steppedRectPath(bodyRect, step: cornerStep))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()

            let innerRect = bodyRect.insetBy(dx: 2, dy: 2)
            ctx.addPath(steppedRectPath(innerRect, step: max(1, cornerStep - 1)))
            ctx.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
            ctx.fillPath()

            // Blocky, stepped tail pointing down toward Bill instead of a
            // smooth triangle.
            let midX = bodyWidth / 2
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill([CGRect(x: midX - 5, y: tailHeight - 3, width: 10, height: 3)])
            ctx.fill([CGRect(x: midX - 3, y: 0, width: 6, height: tailHeight - 2)])

            NSGraphicsContext.current?.shouldAntialias = false
            var y = tailHeight + bodyHeight - paddingY
            for line in lines {
                y -= line.size().height
                line.draw(at: CGPoint(x: paddingX, y: y))
            }
            return true
        }

        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest
        let sprite = SKSpriteNode(texture: texture)
        sprite.setScale(pixelScale)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        return sprite
    }

    private static func wrapText(_ text: String, maxWidth: CGFloat) -> ([NSAttributedString], CGSize) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let words = text.split(separator: " ")
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            let width = (candidate as NSString).size(withAttributes: attrs).width
            if width > maxWidth, !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        if lines.isEmpty { lines = [""] }

        let attributedLines = lines.map { NSAttributedString(string: $0, attributes: attrs) }
        let lineHeight = ceil(font.ascender - font.descender) + 2
        let width = attributedLines.map { $0.size().width }.max() ?? 0
        let height = CGFloat(attributedLines.count) * lineHeight
        return (attributedLines, CGSize(width: width, height: height))
    }

    /// A rectangle with small pixel-stepped corners instead of a smooth
    /// arc — reads as "pixelated rounded rect" rather than a vector oval.
    private static func steppedRectPath(_ rect: CGRect, step: CGFloat) -> CGPath {
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0 + step, y: y0))
        path.addLine(to: CGPoint(x: x1 - step, y: y0))
        path.addLine(to: CGPoint(x: x1, y: y0 + step))
        path.addLine(to: CGPoint(x: x1, y: y1 - step))
        path.addLine(to: CGPoint(x: x1 - step, y: y1))
        path.addLine(to: CGPoint(x: x0 + step, y: y1))
        path.addLine(to: CGPoint(x: x0, y: y1 - step))
        path.addLine(to: CGPoint(x: x0, y: y0 + step))
        path.closeSubpath()
        return path
    }
}
