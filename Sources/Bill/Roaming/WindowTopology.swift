import AppKit
import CoreGraphics

/// The desktop, seen as a platformer level.
///
/// Every on-screen window from another application becomes a solid rect Bill
/// can stand on, climb, or hang from; the screen's `visibleFrame` supplies the
/// ground (above the Dock) and the side walls.
///
/// **Why `CGWindowListCopyWindowInfo` and not the Accessibility API:** window
/// *bounds* from `CGWindowListCopyWindowInfo` require no TCC permission at all
/// — only `kCGWindowName` (titles) and pixel data are gated behind Screen
/// Recording. Deliberately never reading `kCGWindowName` here keeps the whole
/// roaming feature at zero permission prompts. (`WindowTitleReader` is the
/// separate, opt-in path that *does* ask.)
///
/// **Never polled on a timer.** `surfaces(for:)` rebuilds at most once every
/// `cacheLifetime` and only when something actually asks — i.e. when a
/// movement beat begins or a jump target is being re-validated mid-flight.
@MainActor
enum WindowTopology {

    /// A solid, axis-aligned obstacle in Cocoa screen coordinates
    /// (bottom-left origin, Y up) — already flipped from CoreGraphics'
    /// top-left space by `cocoaRect(from:)`.
    struct Platform: Equatable {
        var rect: CGRect
        var ownerPID: pid_t
        var windowNumber: Int
        /// Lower is nearer the front. Taken from the `CGWindowListCopyWindowInfo`
        /// array order, which is documented front-to-back.
        var depth: Int

        /// The walkable ledge along the window's top edge.
        var topY: CGFloat { rect.maxY }
        /// The underside Bill can hang from.
        var bottomY: CGFloat { rect.minY }
    }

    /// Windows smaller than this are tooltips, badges, popovers and shadow
    /// helpers — landing on them looks broken and they vanish constantly.
    private static let minPlatformSize = CGSize(width: 140, height: 90)
    /// A window taller/wider than the whole screen is almost always a
    /// full-screen backdrop or a wallpaper-ish helper; its top edge is the
    /// screen edge, which the screen bounds already provide.
    private static let maxScreenCoverage: CGFloat = 0.995
    /// How long a built topology stays usable before the next request
    /// rebuilds it. Windows do not move fast enough for this to feel stale,
    /// and it collapses a burst of requests during one movement beat into a
    /// single `CGWindowListCopyWindowInfo` call.
    private static let cacheLifetime: TimeInterval = 1.5

    private static var cached: [Platform] = []
    private static var cachedAt: Date = .distantPast

    /// Drops the cache so the next request rebuilds. Called on app
    /// activation and on screen-parameter changes — both are moments when
    /// the window layout is known to have just changed.
    static func invalidate() {
        cachedAt = .distantPast
    }

    /// All solid platforms, front-to-back. `excluding` is our own panel's
    /// window number, which must never become something Bill stands on.
    /// `fresh: true` bypasses the cache. Used by the contact watcher, which
    /// exists specifically to notice windows *moving* and so cannot be served
    /// stale geometry.
    static func platforms(excludingWindowNumber ownWindowNumber: Int, fresh: Bool = false) -> [Platform] {
        if !fresh, Date().timeIntervalSince(cachedAt) < cacheLifetime {
            return cached
        }
        cached = build(excludingWindowNumber: ownWindowNumber)
        cachedAt = Date()
        return cached
    }

    private static func build(excludingWindowNumber ownWindowNumber: Int) -> [Platform] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenRects = NSScreen.screens.map(\.frame)
        var result: [Platform] = []
        result.reserveCapacity(min(raw.count, 32))

        for (index, info) in raw.enumerated() {
            // Layer 0 is the normal application-window layer. Everything else
            // is the Dock (20), the menu bar (24), status items, tooltips,
            // screen-saver and cursor layers — none of which are things a
            // desktop pet should treat as furniture.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let number = info[kCGWindowNumber as String] as? Int, number != ownWindowNumber else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            guard cgRect.width >= minPlatformSize.width, cgRect.height >= minPlatformSize.height else { continue }
            // Fully transparent windows are still "on screen" and would give
            // Bill invisible floors to stand on.
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.35 { continue }

            let rect = cocoaRect(from: cgRect)

            // Must actually be visible on some display, and must not be a
            // screen-sized backdrop (whose top edge duplicates the screen's).
            guard let host = screenRects.first(where: { $0.intersects(rect) }) else { continue }
            // Compared against the *visible* frame, not the raw screen frame.
            //
            // A maximised window is exactly `visibleFrame`-sized, so measuring
            // against the full screen frame (which includes the menu bar and
            // Dock strips) let it through: the roaming trace picked a goal of
            // `top=1074 x=0...1710`, i.e. the entire working area. Jumping
            // "onto" that is jumping at the ceiling, and it also hides every
            // other window behind it.
            let visible = NSScreen.screens.first(where: { $0.frame == host })?.visibleFrame ?? host
            if rect.width >= visible.width * maxScreenCoverage,
               rect.height >= visible.height * maxScreenCoverage { continue }

            result.append(Platform(rect: rect, ownerPID: pid, windowNumber: number, depth: index))
        }
        return result
    }

    /// The frontmost qualifying window belonging to `pid` — this is how Bill
    /// physically "goes to" the app he is about to comment on, and how Study
    /// Mode finds the offending window to stand on.
    static func frontmostPlatform(ownedBy pid: pid_t, excludingWindowNumber ownWindowNumber: Int) -> Platform? {
        platforms(excludingWindowNumber: ownWindowNumber)
            .filter { $0.ownerPID == pid }
            .min { $0.depth < $1.depth }
    }

    // MARK: - Coordinate space

    /// CoreGraphics reports window bounds in *global display space*: origin at
    /// the *primary* display's top-left, Y increasing downward. Cocoa uses the
    /// primary display's bottom-left with Y increasing upward. The flip is
    /// therefore always about the **primary** screen's height, never
    /// `NSScreen.main` (which follows the key window and would silently
    /// produce a whole-screen-height offset the moment a second display is
    /// attached).
    static func cocoaRect(from cgRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? cgRect.maxY
        return CGRect(
            x: cgRect.origin.x,
            y: primaryHeight - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}
