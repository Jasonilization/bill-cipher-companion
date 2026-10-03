import AppKit

/// Shared pixel-border frame view — draws the layered black/accent/fill
/// border around any panel using the same recipe every bubble in the app
/// uses. Used by the pixel chat panel and the full chat view.
final class ChatFrameView: NSView {
    private static let pixelScale: CGFloat = 2
    private static let borderThickness = 2
    private static let accentThickness = 1

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: Self.pixelScale, y: Self.pixelScale)
        let bodyRect = CGRect(
            x: 0, y: 0,
            width: bounds.width / Self.pixelScale,
            height: bounds.height / Self.pixelScale
        )
        // Fill with a dark ink background first — the WebView sits inside
        // and often has its own background, but the border area around
        // it should be Bill's palette.
        BarkBubble.fillPixelRoundedRect(ctx, rect: bodyRect, radius: 8, color: BillPalette.black)
        // Dark chrome: either forced by the Settings preference, or
        // auto-detected from the system appearance.
        let systemDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if AppPreferences.isDarkModeChromeShared || systemDark {
            let inner = bodyRect.insetBy(dx: CGFloat(Self.borderThickness + Self.accentThickness),
                                         dy: CGFloat(Self.borderThickness + Self.accentThickness))
            BarkBubble.fillPixelRoundedRect(ctx, rect: inner, radius: 6,
                                             color: NSColor(calibratedWhite: 0.08, alpha: 1))
        }
        BarkBubble.drawLayeredBorder(
            ctx, bodyRect: bodyRect,
            cornerRadius: 8, borderThickness: Self.borderThickness,
            accentThickness: Self.accentThickness,
            accentColor: BillPalette.bubbleAccent
        )
    }
}
