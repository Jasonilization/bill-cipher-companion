import ApplicationServices
import AppKit
import Foundation

/// Reads the focused window's title from another application, so Bill knows
/// *what* you are looking at rather than only which app you are in — "To-do"
/// in Google Classroom is a very different thing to "Classes".
///
/// **Why Accessibility and not `CGWindowListCopyWindowInfo`:** window *bounds*
/// are unrestricted, but `kCGWindowName` (the title) is redacted without
/// Screen Recording permission. Accessibility gets the same string for a
/// permission that is less invasive and, unlike Screen Recording, does not
/// re-prompt periodically.
///
/// **Two things here matter a lot and are easy to get wrong:**
///
/// 1. **AX calls are synchronous IPC into another process and can block.** If
///    the target app is beachballing, an AX read on the main thread hangs
///    Bill too. Every read here happens off the main actor *and* sets
///    `AXUIElementSetMessagingTimeout`, so a hung app costs a fraction of a
///    second and a `nil`, never a freeze.
/// 2. **It must degrade silently.** If the user never grants Accessibility,
///    everything else about Bill has to keep working exactly as before, with
///    no nagging. `isTrusted` is checked without prompting on every read; the
///    prompt only ever happens when the user explicitly asks for it in
///    Settings.
@MainActor
final class WindowTitleReader {

    /// Whether macOS currently trusts this app for Accessibility. Checked
    /// without prompting.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Explicitly asks for permission. Only ever called from a Settings
    /// button, never automatically.
    ///
    /// Worth knowing: `Scripts/bundle.sh` signs ad-hoc (`codesign -s -`), and
    /// macOS keys the Accessibility grant to the code signature. The signature
    /// changes on every rebuild, so a rebuilt Bill has to be re-granted (and
    /// old entries pile up in the Privacy list). That is a property of ad-hoc
    /// signing, not something this code can work around.
    static func requestTrust() {
        // `kAXTrustedCheckOptionPrompt` is an imported global `var`, which
        // Swift 6 rejects as shared mutable state. The underlying value is a
        // documented constant string, so using it directly is both correct and
        // concurrency-clean.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The focused window title of `pid`, or `nil` if unavailable for any
    /// reason (not trusted, no focused window, app doesn't implement AX, the
    /// app is hung and the read timed out).
    ///
    /// Runs off the main actor because of point 1 above.
    static func focusedWindowTitle(pid: pid_t) async -> String? {
        guard isTrusted else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            let app = AXUIElementCreateApplication(pid)
            // Half a second is plenty for a healthy app and short enough that
            // an unhealthy one is a non-event.
            AXUIElementSetMessagingTimeout(app, 0.5)

            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                  let windowRef = focused
            else { return nil }
            // `CFTypeRef` is `AnyObject`; the AX API hands back an AXUIElement.
            let window = windowRef as! AXUIElement

            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String,
                  !text.isEmpty
            else { return nil }
            return text
        }.value
    }
}

/// Turns a window title into something Bill can have an opinion about.
///
/// Deliberately a small table of substring rules rather than anything clever:
/// titles are the app's own UI copy, they change between versions and
/// languages, and a rule that fails should simply produce `nil` (Bill says
/// nothing extra) rather than a wrong guess.
enum WindowTitleInsight {
    /// A dialogue key plus the substitutions it needs.
    struct Insight {
        var key: String
        var substitutions: [String: String] = [:]
    }

    private struct Rule {
        var appHints: [String]
        var titleHints: [String]
        var key: String
    }

    private static let rules: [Rule] = [
        // Google Classroom — the section tells you whether work is outstanding.
        Rule(appHints: ["classroom"], titleHints: ["to-do", "todo", "to do", "assigned"], key: "insight.classroomTodo"),
        Rule(appHints: ["classroom"], titleHints: ["missing", "overdue"], key: "insight.classroomMissing"),
        Rule(appHints: ["classroom"], titleHints: ["done", "graded", "turned in"], key: "insight.classroomDone"),

        // Google Slides / Docs — an untitled document is a project not started.
        Rule(appHints: ["slides"], titleHints: ["untitled"], key: "insight.slidesUntitled"),
        Rule(appHints: ["docs", "document"], titleHints: ["untitled"], key: "insight.docsUntitled"),

        // Duolingo.
        Rule(appHints: ["duolingo"], titleHints: ["practice", "lesson", "unit"], key: "insight.duolingoLesson"),

        // GitHub.
        Rule(appHints: ["github"], titleHints: ["pull request", "· pull"], key: "insight.githubPR"),
        Rule(appHints: ["github"], titleHints: ["issue"], key: "insight.githubIssue"),

        // YouTube.
        Rule(appHints: ["youtube"], titleHints: ["shorts"], key: "insight.youtubeShorts"),
    ]

    /// `nil` when nothing matches — which is the common case and is correct.
    static func insight(appName: String, title: String) -> Insight? {
        let app = appName.lowercased()
        let text = title.lowercased()
        for rule in rules {
            guard rule.appHints.contains(where: { app.contains($0) || text.contains($0) }) else { continue }
            guard rule.titleHints.contains(where: { text.contains($0) }) else { continue }
            return Insight(key: rule.key, substitutions: ["title": title])
        }
        return nil
    }
}
