import AppKit

/// The chat panel's slim pixel-styled header: a dot-matrix "BILL" label on
/// the left, the panel close button on the right, and a pixel rule along
/// the bottom — replacing the composer's old dead 24pt close-button strip,
/// so the conversation owns the whole panel below the title bar and the
/// composer is exactly as tall as its text box.
///
/// Also the target of the Settings window's drop-by Easter egg (see
/// `CharacterWindowController`), so being seen with the boss counts.
final class PixelChatHeader: NSView {
    let closeButton = PixelCloseButton()
    private let titleView = PixelLabelView(text: "BILL", scale: 2)

    private static let height: CGFloat = 26
    private static let insetX: CGFloat = 8

    var preferredHeight: CGFloat { Self.height }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        addSubview(titleView)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 14
        closeButton.frame = NSRect(
            x: bounds.width - Self.insetX - buttonSize,
            y: bounds.midY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        )
        titleView.frame = NSRect(
            x: Self.insetX,
            y: bounds.midY - titleView.intrinsicHeight / 2,
            width: titleView.intrinsicWidth,
            height: titleView.intrinsicHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.interpolationQuality = .none

        // A two-tone pixel rule: black line with the user's accent as a
        // single highlight row above it — reads as part of the same chrome
        // family as the bubbles below.
        ctx.setFillColor(BillPalette.bubbleAccent.cgColor)
        ctx.fill([CGRect(x: 0, y: 1, width: bounds.width, height: 1)])
        ctx.setFillColor(BillPalette.black.cgColor)
        ctx.fill([CGRect(x: 0, y: 0, width: bounds.width, height: 1)])
        ctx.restoreGState()
    }
}

/// Renders a fixed string once in the hand-built 5x7 dot-matrix font —
/// the same glyph table the bark bubbles use — into a crisp `NSImage`.
/// Title labels only; the app's real text stays in the bubbles.
final class PixelLabelView: NSView {
    private let image: NSImage
    let intrinsicWidth: CGFloat
    let intrinsicHeight: CGFloat

    init(text: String, scale: CGFloat) {
        let lineWidth = PixelFont.lineWidth(text.uppercased())
        let width = lineWidth + 2
        let height = PixelFont.glyphHeight + 2
        intrinsicWidth = width * scale
        intrinsicHeight = height * scale
        image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(false)
            ctx.setAllowsAntialiasing(false)
            let rect = CGRect(x: 0, y: 1, width: width, height: PixelFont.glyphHeight)
            PixelFont.drawCentered(ctx, lines: [text.uppercased()], in: rect, color: BillPalette.black)
            return true
        }
        super.init(frame: NSRect(x: 0, y: 0, width: intrinsicWidth, height: intrinsicHeight))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(
            in: bounds,
            from: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.none]
        )
    }
}
