import AppKit
import ApplicationServices

/// The "push windows around" feature: when a walking character passes in
/// front of an app window, the window gets nudged a few points sideways —
/// smoothly, via the Accessibility API, so it slides rather than snaps.
///
/// Safety rules (the feature moves REAL windows — treat it like the
/// minimize prank, only gentler):
/// - Never the frontmost app's windows (never touch what the user is
///   actively using).
/// - Never our own panel.
/// - Skip unless the AX window is UNAMBIGUOUSLY identified (owning pid +
///   size + converted position). Two same-size windows of one app means
///   no push, never a wrong push.
/// - Abort mid-slide the moment the window moves somewhere we didn't put
///   it (the user grabbed it — never fight a drag).
/// - Per-window cooldown, one push per contact, AX messaging timeouts so
///   a hung app can't stall the main thread.
/// - Completely inert without the Settings toggle AND the Accessibility
///   permission.
///
/// AX reference (Apple, ApplicationServices):
/// - AXUIElementCreateApplication(_:)
///   https://developer.apple.com/documentation/applicationservices/axuielementcreateapplication(_:)
/// - AXUIElementCopyAttributeValue(_:_:_:)
///   https://developer.apple.com/documentation/applicationservices/axuielementcopyattributevalue(_:_:_:)
/// - AXUIElementSetAttributeValue(_:_:_:)
///   https://developer.apple.com/documentation/applicationservices/axuielementsetattributevalue(_:_:_:)
/// - AXValueCreate / AXValueGetValue
///   https://developer.apple.com/documentation/applicationservices/axvaluecreate(_:_:)
///   https://developer.apple.com/documentation/applicationservices/axvaluegetvalue(_:_:_:)
/// - AXUIElementSetMessagingTimeout(_:)
///   https://developer.apple.com/documentation/applicationservices/axuielementsetmessagingtimeout(_:_:)
///
/// Coordinate systems: CGWindowList bounds are top-left origin (y down),
/// AX kAXPosition is bottom-left origin (y up). Conversion between them
/// is only exact for single-display setups; the matcher therefore relies
/// on pid + size first and uses position only as a tie-breaker, and
/// refuses to act on any ambiguity.
@MainActor
enum WindowPusher {
    /// How far a single push shoves the window, in points.
    private static let pushDistance: CGFloat = 24
    /// One push per window per few seconds — a nudge stays a nudge.
    private static var recentlyPushed: [Int: Date] = [:]
    private static let pushCooldown: TimeInterval = 4
    /// The last position WE wrote, so the drag-abort can tell our own
    /// moves from the user's.
    private static var lastWrittenX: [Int: CGFloat] = [:]

    static func maybePush(panel: NSPanel, at feet: CGPoint) {
        guard AppPreferences.isWindowPushingEnabledShared,
              WindowTitleReader.isTrusted,
              let screen = panel.screen ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        guard visible.contains(feet) else { return }

        // The window being walked across: the topmost window whose rect
        // contains the character's feet (excluding our own panel).
        guard let target = WindowTopology
            .platforms(excludingWindowNumber: panel.windowNumber, fresh: true)
            .first(where: { $0.rect.insetBy(dx: -6, dy: -6).contains(feet) })
        else { return }

        // Never the frontmost app — nudging what the user is actively
        // using would be hostile, not playful (same rule as the prank).
        guard let front = NSWorkspace.shared.frontmostApplication,
              target.ownerPID != front.processIdentifier
        else { return }

        // Cooldown per window.
        if let last = recentlyPushed[target.windowNumber],
           Date().timeIntervalSince(last) < pushCooldown { return }
        recentlyPushed[target.windowNumber] = Date()
        if recentlyPushed.count > 16 {
            recentlyPushed = Dictionary(
                recentlyPushed.filter { Date().timeIntervalSince($0.value) < pushCooldown },
                uniquingKeysWith: { a, _ in a }
            )
        }

        // Direction: away from the side the character came from.
        let pushRight = feet.x < target.rect.midX
        slide(window: target, by: pushRight ? pushDistance : -pushDistance)
    }

    /// Resolve the CG window to its AX element. UNAMBIGUOUS matches only:
    /// owning pid first, then size, then converted position as a
    /// tie-breaker; zero or multiple candidates means no push — never a
    /// wrong push.
    private static func resolveAXWindow(target: WindowTopology.Platform) -> AXUIElement? {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]],
              let info = infoList.first(where: {
                  ($0[kCGWindowNumber as String] as? Int) == target.windowNumber
              }),
              let pid = info[kCGWindowOwnerPID as String] as? Int,
              let frame = info[kCGWindowBounds as String] as? [String: Any],
              let w = frame["Width"] as? CGFloat,
              let h = frame["Height"] as? CGFloat
        else { return nil }

        let app = AXUIElementCreateApplication(pid_t(pid))
        // A hung app costs at most a fraction of a second, never the
        // default multi-second AX timeout on the main thread.
        AXUIElementSetMessagingTimeout(app, 0.4)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windowsRef = windowsValue,
              let axWindows = (windowsRef as? NSArray) as? [AXUIElement]
        else { return nil }

        // CG bounds are top-left origin; AX is bottom-left. The primary
        // display height converts between them (exact single-display;
        // only a tie-breaker here).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgY = frame["Y"] as? CGFloat ?? 0
        let expectedOrigin = CGPoint(x: frame["X"] as? CGFloat ?? 0,
                                     y: primaryHeight - cgY - h)

        // UNAMBIGUOUS match: owning pid (already filtered by using this
        // app's window list) + size + converted position. Zero or
        // multiple candidates means no push — never a wrong push.
        var matches: [AXUIElement] = []
        for axWindow in axWindows {
            AXUIElementSetMessagingTimeout(axWindow, 0.4)
            guard let position = axPoint(axWindow, attribute: kAXPositionAttribute),
                  let size = axSize(axWindow)
            else { continue }
            guard abs(size.width - w) < 1.5, abs(size.height - h) < 1.5 else { continue }
            guard abs(position.x - expectedOrigin.x) < 3,
                  abs(position.y - expectedOrigin.y) < 3
            else { continue }
            matches.append(axWindow)
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    /// Read a CGPoint attribute (kAXPositionAttribute) from an AX element.
    private static func axPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let ref = value
        else { return nil }
        // CF types bridge unconditionally — same forced-downcast form the
        // toolchain-proven WindowTitleReader uses for AXUIElement.
        let axValue = ref as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// Read the kAXSizeAttribute from an AX element.
    private static func axSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let ref = value
        else { return nil }
        let axValue = ref as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Smooth push: ~6 small AX position writes over ~0.18s — a slide,
    /// not a teleport. Aborts the instant the window moves somewhere we
    /// didn't write (the user grabbed it), and skips gracefully when the
    /// window isn't AX-movable (fullscreen, some system windows).
    private static func slide(window: WindowTopology.Platform, by dx: CGFloat) {
        guard let axWindow = resolveAXWindow(target: window) else { return }
        guard var point = axPoint(axWindow, attribute: kAXPositionAttribute) else { return }

        // Check it's actually settable before starting — some windows
        // refuse silently and we don't want failed writes mid-slide.
        guard write(axWindow, windowNumber: window.windowNumber, to: point) else { return }

        let steps = 6
        let stepDX = dx / CGFloat(steps)
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.03) {
                // Drag-abort: if the window isn't exactly where the last
                // write left it, the user is moving it — stop immediately.
                guard let current = axPoint(axWindow, attribute: kAXPositionAttribute),
                      let lastX = lastWrittenX[window.windowNumber],
                      abs(current.x - lastX) < 3
                else { return }
                point = current
                point.x += stepDX
                _ = write(axWindow, windowNumber: window.windowNumber, to: point)
            }
        }
    }

    /// One AX position write. Records what we wrote for the drag-abort.
    private static func write(_ element: AXUIElement, windowNumber: Int, to point: CGPoint) -> Bool {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
        else { return false }
        lastWrittenX[windowNumber] = point.x
        return true
    }
}
