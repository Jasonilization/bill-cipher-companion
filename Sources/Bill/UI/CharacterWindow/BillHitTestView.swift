import AppKit
import SpriteKit

/// An `SKView` that only intercepts clicks over Bill's actual silhouette —
/// everywhere else in the (otherwise fully transparent) character window,
/// clicks pass straight through to whatever's on the desktop behind it.
/// Also turns mouse-down-and-move into dragging Bill to a new spot, and a
/// plain click into a reaction.
@MainActor
final class BillHitTestView: SKView {
    var onClick: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    /// Bill's approximate on-screen silhouette (body + limbs + hat), in this
    /// view's local coordinates. A fixed rect rather than a precise
    /// per-pixel/per-node hit test — simple, predictable, and tight enough
    /// to leave the large empty headroom above his hat (reserved for the
    /// bark bubble) click-through.
    var hitRegion = CGRect(x: 60, y: 25, width: 140, height: 195)

    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var isDragging = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is documented as being in the superview's coordinate
        // space — but a borderless panel's direct contentView typically has
        // no superview at all, in which case the point is already
        // effectively in this view's own local space.
        let localPoint = superview?.convert(point, to: self) ?? point
        return hitRegion.contains(localPoint) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouseLocation, let startOrigin = dragStartWindowOrigin, let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - start.x
        let dy = current.y - start.y

        if !isDragging, abs(dx) > 3 || abs(dy) > 3 {
            isDragging = true
            onDragStarted?()
        }
        if isDragging {
            let proposed = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
            window.setFrameOrigin(clampedOrigin(for: proposed))
        }
    }

    /// Keeps Bill's *silhouette* on screen, rather than his window.
    ///
    /// `BillPanel` deliberately opts out of AppKit's own frame constraint so
    /// that the tall empty bark-bubble headroom above his hat can run off
    /// the top of the screen (otherwise that headroom hits the menu bar and
    /// Bill stops well short of the top — the bug this exists to fix). That
    /// removes the only thing stopping a drag from parking him somewhere
    /// unreachable, so the constraint is reapplied here against
    /// `hitRegion` — the part of the window that's actually *him*, and the
    /// only part that can be grabbed to drag him back.
    private func clampedOrigin(for proposed: NSPoint) -> NSPoint {
        let regionOnScreen = hitRegion.offsetBy(dx: proposed.x, dy: proposed.y)
        let screen = NSScreen.screens.first { $0.frame.intersects(regionOnScreen) }
            ?? window?.screen
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return proposed }

        return NSPoint(
            x: min(max(proposed.x, visible.minX - hitRegion.minX), visible.maxX - hitRegion.maxX),
            y: min(max(proposed.y, visible.minY - hitRegion.minY), visible.maxY - hitRegion.maxY)
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartMouseLocation = nil
            dragStartWindowOrigin = nil
        }
        if isDragging {
            isDragging = false
            onDragEnded?()
        } else {
            onClick?()
        }
    }

    /// Right-click shows Bill's small context menu ("Talk", etc.) rather
    /// than the system's default empty menu.
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}
