import AppKit

/// Owns the bark bubble as a separate NSPanel — completely decoupled from
/// Bill's character window. This is the fix for the persistent "cropped by
/// his window size" bug: a bark can now go directly left, right, above, or
/// below Bill because it's a free-floating window, not an SKNode inside a
/// 260pt SKView. No scene coordinate conversion, no window resizing, no
/// SKView clipping.
@MainActor
final class BarkPanelController: NSObject {
    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var dismissWork: DispatchWorkItem?
    /// The panel's current position relative to Bill (for the re-clamp
    /// when Bill moves).
    private var lastBillFrame: NSRect?

    /// The gap between the tail tip and Bill, in screen points.
    private static let gap: CGFloat = 6
    private static let fadeDuration: TimeInterval = 0.22
    /// Minimum reading time + proportional extra.
    private static let minimumDisplay: TimeInterval = 2.5

    // MARK: - Show

    /// Shows a bark bubble near `billFrame` in the direction that has room.
    /// Picks a random direction when the screen has room everywhere
    /// (adaptive), and away from the border when Bill is near one.
    func show(text: String, near billFrame: NSRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let maxWidth: CGFloat = 240
        let gap = Self.gap

        // Room in each direction from Bill's edges to the screen bounds.
        let roomRight = visible.maxX - billFrame.maxX - gap
        let roomLeft = billFrame.minX - visible.minX - gap
        let roomAbove = visible.maxY - billFrame.maxY - gap
        let roomBelow = billFrame.minY - visible.minY - gap

        // Adaptive: random direction when there's comfortable room
        // everywhere; away from the border when near one.
        enum Direction {
            case left, right, above, below
        }
        let allRoomy = roomLeft > 120 && roomRight > 120 && roomAbove > 120 && roomBelow > 60
        let direction: Direction
        if allRoomy {
            direction = [.left, .right, .above, .below].randomElement()!
        } else if roomRight >= roomLeft && roomRight > 80 {
            direction = .right
        } else if roomLeft > 80 {
            direction = .left
        } else if roomAbove > 80 {
            direction = .above
        } else {
            direction = .below
        }

        // Build the bubble image for the chosen direction.
        let result: (image: NSImage, displaySize: NSSize)
        switch direction {
        case .left:
            result = BarkBubble.makeImage(
                text: text, maxWidth: roomLeft, maxHeight: visible.height * 0.6,
                tailEdge: .rightSide
            )
        case .right:
            result = BarkBubble.makeImage(
                text: text, maxWidth: roomRight, maxHeight: visible.height * 0.6,
                tailEdge: .leftSide
            )
        case .above:
            result = BarkBubble.makeImage(
                text: text, maxWidth: max(160, min(maxWidth, visible.width * 0.2)),
                maxHeight: roomAbove, tailEdge: .above
            )
        case .below:
            result = BarkBubble.makeImage(
                text: text, maxWidth: max(160, min(maxWidth, visible.width * 0.2)),
                maxHeight: roomBelow, tailEdge: .below
            )
        }

        let image = result.image
        let size = result.displaySize

        // Compute the panel's frame based on the direction.
        var frame: NSRect
        switch direction {
        case .left:
            frame = NSRect(
                x: billFrame.minX - gap - size.width,
                y: billFrame.midY - size.height / 2,
                width: size.width, height: size.height
            )
        case .right:
            frame = NSRect(
                x: billFrame.maxX + gap,
                y: billFrame.midY - size.height / 2,
                width: size.width, height: size.height
            )
        case .above:
            frame = NSRect(
                x: billFrame.midX - size.width / 2,
                y: billFrame.maxY + gap,
                width: size.width, height: size.height
            )
        case .below:
            frame = NSRect(
                x: billFrame.midX - size.width / 2,
                y: billFrame.minY - gap - size.height,
                width: size.width, height: size.height
            )
        }

        // Clamp into the visible frame.
        if frame.maxX > visible.maxX {
            frame.origin.x = visible.maxX - frame.width
        }
        if frame.minX < visible.minX {
            frame.origin.x = visible.minX
        }
        if frame.maxY > visible.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }

        // Create or reuse the panel.
        if panel == nil {
            let p = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.ignoresMouseEvents = true
            let iv = NSImageView()
            iv.imageScaling = .scaleNone
            iv.autoresizingMask = [.width, .height]
            p.contentView = iv
            panel = p
            imageView = iv
        }

        panel?.setFrame(frame, display: true)
        imageView?.image = image
        lastBillFrame = billFrame

        // Fade in.
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            panel?.animator().alphaValue = 1
        }

        // Schedule dismissal.
        dismissWork?.cancel()
        let displayDuration = max(Self.minimumDisplay, min(6.0, Double(text.count) * 0.045))
        let work = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: work)
    }

    func fadeOut() {
        dismissWork?.cancel()
        dismissWork = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            panel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    /// Re-clamps the showing bark into the visible frame when Bill moves.
    func reposition(near billFrame: NSRect, on screen: NSScreen) {
        guard let panel, panel.isVisible else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        // Keep the same relative position — just clamp into the screen.
        if frame.maxX > visible.maxX {
            frame.origin.x = visible.maxX - frame.width
        }
        if frame.minX < visible.minX {
            frame.origin.x = visible.minX
        }
        if frame.maxY > visible.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        if frame != panel.frame {
            panel.setFrameOrigin(frame.origin)
        }
        lastBillFrame = billFrame
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}
