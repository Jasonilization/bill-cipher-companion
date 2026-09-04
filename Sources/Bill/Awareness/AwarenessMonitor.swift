import AppKit
import Foundation

/// Periodically looks at what's on screen, rather than only reacting the
/// instant you switch apps.
///
/// App activation is a poor sole trigger for this: you open Google Classroom
/// once and then sit in it for twenty minutes, and the interesting change —
/// finishing an assignment, a new item appearing — happens long after the
/// activation. So this samples on a slow timer as well.
///
/// Cheap by construction:
/// - the timer only exists while awareness is switched on;
/// - a tick does nothing unless the frontmost app is one worth reading;
/// - the title read is a sub-millisecond Accessibility call, off the main actor;
/// - the capture+OCR path (the expensive one) is opt-in, and additionally rate
///   limited per app inside `ScreenTextReader`.
@MainActor
final class AwarenessMonitor {
    /// Emits a dialogue key + substitutions when it notices something.
    var onInsight: ((WindowTitleInsight.Insight) -> Void)?

    private let preferences: AppPreferences
    private let screenReader = ScreenTextReader()
    private var timer: Timer?
    /// Suppresses repeating the same observation over and over while you sit
    /// in one place.
    private var lastEmitted: [String: Date] = [:]
    private static let repeatCooldown: TimeInterval = 25 * 60
    private static let interval: TimeInterval = 5 * 60

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func start() {
        stop()
        guard preferences.isWindowAwarenessEnabled else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads the preference and starts/stops accordingly.
    func refresh() {
        preferences.isWindowAwarenessEnabled ? start() : stop()
    }

    private func sample() async {
        guard preferences.isWindowAwarenessEnabled,
              let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName
        else { return }
        guard let insight = await inspect(pid: app.processIdentifier, appName: name) else { return }
        if let last = lastEmitted[insight.key], Date().timeIntervalSince(last) < Self.repeatCooldown { return }
        lastEmitted[insight.key] = Date()
        onInsight?(insight)
    }

    /// Shared by the periodic sample and the debug test button.
    func inspect(pid: pid_t, appName: String) async -> WindowTitleInsight.Insight? {
        var resolved: WindowTitleInsight.Insight?
        if let title = await WindowTitleReader.focusedWindowTitle(pid: pid) {
            resolved = WindowTitleInsight.insight(appName: appName, title: title)
        }
        if preferences.isScreenOCREnabled,
           let text = await screenReader.readFocusedWindow(pid: pid, appName: appName),
           let deeper = ScreenTextInsight.insight(appName: appName, text: text) {
            resolved = deeper
        }
        return resolved
    }

    // MARK: - Diagnostics

    /// Runs the whole pipeline against the frontmost app right now and reports
    /// exactly what each stage produced.
    ///
    /// This exists because every stage of window awareness fails *silently* by
    /// design — no permission, no title, no match and no capture all look
    /// identical from the outside (Bill just says nothing). Without a way to
    /// see the stages, "it doesn't work" is unfalsifiable.
    func diagnose() async -> String {
        var out: [String] = []

        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else {
            return "No frontmost application."
        }
        let pid = app.processIdentifier
        out.append("Frontmost app:  \(name)  (pid \(pid))")
        out.append("")

        // 1. Titles
        out.append("① WINDOW TITLE")
        out.append("   Setting enabled:  \(preferences.isWindowAwarenessEnabled ? "yes" : "NO — turn on in Settings")")
        out.append("   Accessibility:    \(WindowTitleReader.isTrusted ? "granted" : "NOT GRANTED — grant it in Settings")")
        let started = Date()
        let title = await WindowTitleReader.focusedWindowTitle(pid: pid)
        let titleMs = Int(Date().timeIntervalSince(started) * 1000)
        out.append("   Title read:       \(title.map { "\"\($0)\"" } ?? "nil") (\(titleMs)ms)")
        if let title {
            let insight = WindowTitleInsight.insight(appName: name, title: title)
            out.append("   Matched rule:     \(insight?.key ?? "none — no rule covers this app/title")")
        }
        out.append("")

        // 2. Screenshot + OCR
        out.append("② SCREENSHOT + OCR")
        out.append("   Setting enabled:  \(preferences.isScreenOCREnabled ? "yes" : "NO — turn on in Settings")")
        out.append("   Screen Recording: \(ScreenTextReader.hasPermission ? "granted" : "NOT GRANTED — grant it in Settings")")
        out.append("   App worth reading: \(ScreenTextReader.isInteresting(appName: name) ? "yes" : "no — only Classroom/Slides/Docs/Duolingo/Gmail are read")")
        if preferences.isScreenOCREnabled, ScreenTextReader.hasPermission {
            let t0 = Date()
            // `force` bypasses the per-app cooldown so the test button always
            // does real work instead of silently reporting a stale skip.
            let text = await screenReader.readFocusedWindow(pid: pid, appName: name, force: true)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if let text {
                let lines = text.split(separator: "\n")
                out.append("   Captured + read:  \(lines.count) text runs, \(text.count) chars (\(ms)ms)")
                out.append("   First few runs:   \(lines.prefix(5).joined(separator: " ⁄ "))")
                let insight = ScreenTextInsight.insight(appName: name, text: text)
                out.append("   Matched rule:     \(insight?.key ?? "none — no count/keyword rule matched")")
            } else {
                out.append("   Captured + read:  nothing (\(ms)ms) — window too small, or not an app we read")
            }
        }
        out.append("")

        let final = await inspect(pid: pid, appName: name)
        out.append("RESULT: \(final.map { "would say \($0.key)" } ?? "nothing to say about this window")")
        return out.joined(separator: "\n")
    }
}
