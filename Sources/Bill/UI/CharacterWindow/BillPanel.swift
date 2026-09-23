import AppKit

/// Bill's character window.
///
/// The only reason this subclass exists is `constrainFrameRect(_:to:)`.
/// AppKit's default implementation refuses to place a window's top edge
/// above the screen's visible top (the bottom of the menu bar) — sensible
/// for a normal document window, actively wrong for Bill. His window is
/// deliberately *much* taller than he is: the top ~2/3 is empty,
/// click-through headroom reserved for a tall bark bubble above his hat.
/// With the default constraint, that empty headroom is what bumps into the
/// menu bar, so Bill himself stops roughly 60% of the way up the screen and
/// simply cannot be dragged (or scaled) any higher — and the taller the
/// window gets at larger scale, the lower he's pinned. Returning the
/// requested rect untouched lets the headroom run off the top of the screen
/// so Bill's own body can reach the actual top edge.
///
/// Dropping the constraint means AppKit will no longer stop him being moved
/// somewhere unreachable either, so keeping him on screen becomes this
/// app's own job — see `BillHitTestView.clampedOrigin(for:)`, which
/// constrains drags against Bill's *silhouette* rather than this oversized
/// frame.
final class BillPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
