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
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
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
}
