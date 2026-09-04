import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// The opt-in, deeper half of window awareness: capture just the focused
/// window and read it on-device, so Bill can tell "you have three assignments
/// due" from "you have Classroom open".
///
/// **Strictly opt-in and strictly rate limited.** A capture plus OCR is orders
/// of magnitude more expensive than reading a title — hundreds of milliseconds
/// of CPU and a full-window bitmap in memory — so:
///
/// - it never runs unless the user has turned it on in Settings;
/// - it only runs for apps on `interestingApps`, not for everything;
/// - it runs at most once per app per `perAppCooldown`;
/// - everything happens off the main actor, and the bitmap is released as soon
///   as Vision is done with it.
///
/// **Permission:** Screen Recording. Because this app is ad-hoc signed
/// (`Scripts/bundle.sh` uses `codesign -s -`), the grant is keyed to a
/// signature that changes on every rebuild, so it has to be re-granted each
/// time. That is why this is separate from the title toggle rather than folded
/// into it — titles keep working across rebuilds, this does not.
@MainActor
final class ScreenTextReader {
    private var lastCapture: [pid_t: Date] = [:]
    private static let perAppCooldown: TimeInterval = 20 * 60

    /// Only apps where reading the contents tells Bill something he cannot get
    /// from the title alone. Everything else is not worth the cost.
    private static let interestingApps = ["classroom", "slides", "docs", "duolingo", "gmail"]
    /// Capture is downscaled to this long edge before recognition.
    ///
    /// Measured on this machine, and the numbers are stark:
    ///   full-screen native + `.fast`      →  9.7s
    ///   ~1000pt window native + `.accurate` → 85.7s  (!)
    /// `.accurate` reads UI text far better ("Apple Account" vs "APPL Y
    /// IHANGES?"), but nearly a minute and a half of a saturated core for a
    /// background nicety is indefensible. The fix is to make the *image*
    /// small enough that `.fast` is sufficient, rather than to pay for
    /// `.accurate` on a large one.
    private static let maxCaptureLongEdge: CGFloat = 1000

    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts for Screen Recording. Only ever called from Settings.
    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func isInteresting(appName: String) -> Bool {
        let name = appName.lowercased()
        return interestingApps.contains { name.contains($0) }
    }

    /// Recognised text from the frontmost window of `pid`, or `nil` if capture
    /// is unavailable, on cooldown, or produced nothing.
    func readFocusedWindow(pid: pid_t, appName: String, force: Bool = false) async -> String? {
        guard Self.hasPermission, force || Self.isInteresting(appName: appName) else { return nil }
        if !force, let last = lastCapture[pid], Date().timeIntervalSince(last) < Self.perAppCooldown { return nil }
        lastCapture[pid] = Date()

        guard let image = await Self.capture(pid: pid) else { return nil }
        return await Self.recognizeText(in: image)
    }

    private static func capture(pid: pid_t) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // Frontmost qualifying window belonging to this process. `windows`
            // comes back front-to-back, so the first match is the one on top.
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == pid && ($0.frame.width > 200 && $0.frame.height > 150)
            }) else { return nil }

            let config = SCStreamConfiguration()
            // Cap the long edge.
            //
            // Measured: capturing a full-screen window at native size and
            // running Vision over it took **9.7 seconds**. `SCStreamConfiguration`
            // sizes are in *pixels*, so a Retina full-screen window is ~7.6M
            // pixels — far more than text recognition needs. Downscaling to a
            // 1400px long edge cuts that by roughly an order of magnitude while
            // leaving UI text comfortably legible.
            // `window.frame` is in points; `SCStreamConfiguration` sizes are
            // in *pixels*, and on a Retina display the native capture is 2x.
            // Sizing from points alone therefore silently captured a
            // double-resolution image — which is why the first cap barely
            // helped. Scale down from the true pixel size.
            let pixelScale = NSScreen.main?.backingScaleFactor ?? 2
            let pixelWidth = window.frame.width * pixelScale
            let pixelHeight = window.frame.height * pixelScale
            let longEdge = max(pixelWidth, pixelHeight)
            let factor = min(1.0, Self.maxCaptureLongEdge / max(longEdge, 1))
            config.width = max(1, Int(pixelWidth * factor))
            config.height = max(1, Int(pixelHeight * factor))
            config.scalesToFit = true
            config.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("ScreenTextReader: capture failed: \(error)")
            return nil
        }
    }

    private static func recognizeText(in image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            // Off the main actor entirely — Vision on a full window is the
            // single most expensive thing this app can do.
            // `.userInitiated`, not `.utility`: at utility QoS this work is
            // aggressively descheduled whenever the main thread is busy (which,
            // during a roaming beat, it is), stretching an already slow pass out
            // even further.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                // Correction stays ON even at `.fast` — it is cheap at this
                // level and it is what turns "APPL Y IHANGES" into something
                // the keyword rules can match.
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US"]
                // Skip text smaller than ~1.5% of the image height. UI labels
                // and counts are well above that, and ignoring the fine print
                // removes most of the work.
                request.minimumTextHeight = 0.015
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let strings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: strings.isEmpty ? nil : strings.joined(separator: "\n"))
            }
        }
    }
}

/// Turns recognised on-screen text into an insight key.
///
/// Same philosophy as `WindowTitleInsight`: a small, honest rule table where a
/// miss produces `nil`. It looks for *counts* — the thing a title can never
/// give you.
enum ScreenTextInsight {
    static func insight(appName: String, text: String) -> WindowTitleInsight.Insight? {
        let app = appName.lowercased()
        let body = text.lowercased()

        if app.contains("classroom") {
            if let count = firstNumber(before: "missing", in: body), count > 0 {
                return .init(key: "insight.classroomMissingCount", substitutions: ["count": String(count)])
            }
            if body.contains("no work due") || body.contains("nice work") || body.contains("you're all caught up") {
                return .init(key: "insight.classroomClear")
            }
            if let count = firstNumber(before: "assigned", in: body), count > 0 {
                return .init(key: "insight.classroomAssignedCount", substitutions: ["count": String(count)])
            }
            if body.contains("due today") {
                return .init(key: "insight.classroomDueToday")
            }
        }
        return nil
    }

    /// Finds "3 missing" / "missing (3)" style counts without a regex engine
    /// pass over the whole document.
    private static func firstNumber(before keyword: String, in text: String) -> Int? {
        guard let range = text.range(of: keyword) else { return nil }
        let windowStart = text.index(range.lowerBound, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex
        let before = String(text[windowStart..<range.lowerBound])
        let beforeDigits = before.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if let last = beforeDigits.last { return last }
        // Also allow "missing (3)".
        let after = String(text[range.upperBound...].prefix(8))
        return after.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
    }
}
