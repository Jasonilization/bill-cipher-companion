import AppKit
import Foundation

/// A 30-minute enforced focus session.
///
/// **Blocklist-first, not allowlist-first.** The requested rule was "coding,
/// gaming, Blender, SDR, Scarab, Docker, Pragmata, Terminal, Wireshark, Gmail
/// and all chat platforms are out; Slides, Classroom, Notes, Spotify, Docs,
/// Canva, Safari *and other needed apps* are in." That last clause is the
/// deciding one: an allowlist cannot express "and anything else you legitimately
/// need", and would block a password manager, a PDF viewer, or a dictionary the
/// first time the user reached for one. So everything is permitted except what
/// is named, plus an explicit allow-override for the apps that would otherwise
/// be caught by a blocked *category* (Canva is `creative`, and `creative` is
/// not blocked, but Blender is).
///
/// **Enforcement escalates**, as requested: first offence is a warning only,
/// the second hides the app, the third and beyond hide it immediately and Bill
/// gets progressively less polite. Hiding uses `NSRunningApplication.hide()`,
/// which is reversible, needs no permissions, and cannot lose unsaved work —
/// unlike terminating, which was explicitly considered and rejected.
@MainActor
final class StudyMode {
    /// Fires when the session state changes, so the menu/settings checkmarks
    /// can follow along.
    var onStateChanged: (() -> Void)?
    /// Requests a bark + animation. Wired to `ReactionRouter`.
    var announce: ((_ keys: [String], _ states: [BillState], _ substitutions: [String: String]) -> Void)?
    /// Sends Bill to physically confront the offending window.
    var goToApp: ((pid_t) -> Bool)?

    private(set) var endsAt: Date?
    private var halfwayFired = false
    private var timer: Timer?
    private var offences: [String: Int] = [:]
    private var lastAllowedPID: pid_t?

    static let sessionLength: TimeInterval = 30 * 60
    private static let halfwayPoint: TimeInterval = 15 * 60
    private static let defaultsKey = "billStudyModeEndsAt"

    var isActive: Bool {
        guard let endsAt else { return false }
        return endsAt > Date()
    }

    var remaining: TimeInterval {
        guard let endsAt else { return 0 }
        return max(0, endsAt.timeIntervalSinceNow)
    }

    init() {
        // A session survives a relaunch. Quitting and reopening Bill should
        // not be a way to escape the thirty minutes you asked for.
        if let stored = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Date, stored > Date() {
            endsAt = stored
            halfwayFired = stored.timeIntervalSinceNow < Self.halfwayPoint
            scheduleTick()
        }
    }

    // MARK: - Session control

    func start() {
        endsAt = Date().addingTimeInterval(Self.sessionLength)
        UserDefaults.standard.set(endsAt, forKey: Self.defaultsKey)
        halfwayFired = false
        offences.removeAll()
        announce?(["study.start"], [.cultLeader, .summoning, .focused, .channeling], [:])
        scheduleTick()
        onStateChanged?()
    }

    /// The safety valve.
    ///
    /// The request was that study mode "forces" thirty minutes, and it does —
    /// it survives relaunch, and the blocked apps stay blocked. But software
    /// that genuinely cannot be switched off is a trap, not a feature: a real
    /// emergency, a misfire, or simply changing your mind all have to be
    /// possible. So cancelling works, and costs a confirmation and a pointed
    /// remark rather than being impossible.
    func cancel(confirmed: Bool) -> Bool {
        guard isActive else { return true }
        if !confirmed { return false }
        finish(completed: false)
        return true
    }

    private func finish(completed: Bool) {
        timer?.invalidate(); timer = nil
        endsAt = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        offences.removeAll()
        announce?(
            [completed ? "study.end" : "study.cancelled"],
            completed ? [.celebrating, .happy, .dancing, .powerSurge] : [.dreading, .guilty, .grumpEyes],
            [:]
        )
        onStateChanged?()
    }

    private func scheduleTick() {
        timer?.invalidate()
        // One timer, re-armed at each milestone — not a per-second countdown.
        let next = halfwayFired ? remaining : max(1, remaining - Self.halfwayPoint)
        timer = Timer.scheduledTimer(withTimeInterval: max(1, next), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isActive else { finish(completed: true); return }
        if !halfwayFired {
            halfwayFired = true
            announce?(["study.halfway"], [.celebrating, .presenting, .happy, .kinship], [:])
            scheduleTick()
            return
        }
        finish(completed: true)
    }

    // MARK: - Enforcement

    /// Called for every app activation while a session is running. Returns
    /// `true` if this activation was handled (blocked), so the normal reaction
    /// path stands down.
    func intercept(bundleID: String, name: String, pid: pid_t) -> Bool {
        guard isActive else { return false }

        guard StudyPolicy.isBlocked(bundleID: bundleID, name: name) else {
            lastAllowedPID = pid
            return false
        }

        let offence = (offences[bundleID] ?? 0) + 1
        offences[bundleID] = offence

        // Bill goes there first, so the confrontation happens at the window
        // rather than from across the desktop.
        _ = goToApp?(pid)

        let states: [BillState] = offence == 1 ? [.watched, .grumpEyes, .huffy]
                               : offence == 2 ? [.annoyed, .dreading, .stressed]
                                              : [.rampaging, .meltdown, .cultLeader, .shadowHands]
        announce?(DialogueKey.studyBlocked(offence: offence), states, ["app": name])

        // First offence is a warning only.
        guard offence >= 2 else { return true }

        // Give the bark a beat to land before the window disappears, so the
        // hide reads as Bill doing it rather than as the app crashing.
        let delay: TimeInterval = offence == 2 ? 1.6 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in self?.hide(pid: pid) }
        }
        return true
    }

    private func hide(pid: pid_t) {
        guard isActive else { return }
        NSRunningApplication(processIdentifier: pid)?.hide()
        // Put the user back where they were allowed to be. If there is no such
        // app (study mode started with only blocked apps running), do nothing
        // rather than yanking focus somewhere arbitrary.
        if let lastAllowedPID, lastAllowedPID != pid {
            NSRunningApplication(processIdentifier: lastAllowedPID)?
                .activate(options: [.activateAllWindows])
        }
    }
}

/// What Study Mode blocks. Separated from the session machinery so the policy
/// is readable and testable on its own.
enum StudyPolicy {
    /// Categories that are wholesale off-limits.
    ///
    /// `communication` covers the "Gmail and all chatting platforms" rule —
    /// mail and chat apps share that category already, so blocking it is both
    /// the simplest expression of the request and the one that automatically
    /// covers a chat app the user installs later.
    static let blockedCategories: Set<AppCategory> = [.coding, .gaming, .tinkering, .communication]

    /// Named apps that are blocked even though their category is not.
    /// Matched case-insensitively against bundle ID *and* display name,
    /// because Safari Web Apps get a random per-install UUID bundle ID and can
    /// only be identified by name.
    static let blockedNames: [String] = [
        "blender", "terminal", "iterm", "docker", "wireshark",
        "sdr", "satdump", "scarab", "pragmata",
        "gmail", "discord", "slack", "telegram", "whatsapp", "messenger", "signal",
        "steam", "epicgames", "battle.net",
    ]

    /// Explicitly permitted even if something above would otherwise catch
    /// them. Checked first, so this always wins.
    static let allowedNames: [String] = [
        "safari", "spotify", "notes", "canva", "preview", "calculator", "dictionary",
        "google slides", "google docs", "google classroom", "classroom", "slides", "docs",
        "keynote", "pages", "numbers", "calendar", "reminders", "books", "freeform",
    ]

    /// Precedence matters here, and getting it wrong has a specific, sharp
    /// failure mode.
    ///
    /// Safari Web Apps have bundle IDs of the form
    /// `com.apple.Safari.WebApp.<random-UUID>` and are only identifiable by
    /// their display name. Matching the allow-list against bundle ID *and*
    /// name together meant a Gmail web app — bundle ID containing "safari",
    /// display name "Gmail" — matched `safari` on the allow-list and sailed
    /// straight through, despite Gmail being explicitly named as blocked.
    /// The same hole would let any blocked site installed as a web app past.
    ///
    /// So: the **display name** is checked against the block-list first and
    /// wins outright; the allow-list is only consulted for names, never bundle
    /// IDs; and bundle IDs are only ever used to *block*.
    static func isBlocked(bundleID: String, name: String) -> Bool {
        let lowerName = name.lowercased()
        let lowerBundle = bundleID.lowercased()

        if blockedNames.contains(where: { lowerName.contains($0) }) { return true }
        if allowedNames.contains(where: { lowerName.contains($0) }) { return false }
        if blockedNames.contains(where: { lowerBundle.contains($0) }) { return true }

        guard let category = AppCategoryMapper.category(bundleID: bundleID, bundleURL: nil, name: name) else {
            // Unknown apps are allowed — see the type's doc comment on why
            // this is a blocklist.
            return false
        }
        return blockedCategories.contains(category)
    }
}
