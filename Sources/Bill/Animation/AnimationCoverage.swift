import Foundation

/// Makes sure every animation Bill owns actually gets seen.
///
/// Two guarantees, both requested explicitly:
///
/// 1. **Never the same animation twice in a row.** Every path that *chooses*
///    between candidate animations goes through `pick(from:)`, which refuses
///    to return whatever played last. (Triggers with exactly one correct
///    animation — plugging in the charger is always `.charging` — are not
///    routed through here, because suppressing those would be wrong, not
///    varied.)
///
/// 2. **Every animation appears at least once a day.** `unseenToday()` reports
///    what has not been shown yet, `pick(from:)` prefers those, and
///    `nextCatchUpDelay()` paces a background showcase so anything the day's
///    ordinary triggers never happened to reach still gets its moment.
///
/// The honest limit on guarantee 2: Bill can only perform while the app is
/// running and the user is present. On a day the machine is barely switched
/// on, the leftovers roll over rather than being silently marked seen —
/// `staleness` then biases them to the front of the queue the next day.
@MainActor
final class AnimationCoverage {

    private struct Store: Codable {
        /// `BillState.rawValue` -> when it last actually played.
        var lastPlayed: [String: Date] = [:]
        /// `BillState.rawValue` -> how many distinct days it has been shown.
        var daysShown: [String: Int] = [:]
        var lastRolloverDay: String = ""
    }

    private var store = Store()
    private var lastPicked: BillState?
    private let url: URL

    /// States that must never be auto-showcased: they are either driven by
    /// the physics simulation (showing a `falling` frame while standing still
    /// looks broken), or they are a resting pose rather than a performance.
    private static let notShowcaseable: Set<BillState> = [
        .idle, .walking, .running, .crouching, .launching, .rising, .falling,
        .landingSoft, .landingHard, .ledgeGrabbing, .climbingUp, .climbingDown,
        .hangingIdle, .edgePeek, .sleeping, .charging, .heatingUp,
    ]

    /// Everything the daily sweep is responsible for getting on screen.
    static var showcaseable: [BillState] {
        BillState.allCases.filter { !notShowcaseable.contains($0) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(filename: String = "animation-coverage.json") {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bill", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            store = decoded
        }
        rolloverIfNeeded()
    }

    // MARK: - Recording

    /// Called by `BillStateMachine` every time a clip genuinely starts.
    func record(_ state: BillState) {
        rolloverIfNeeded()
        let key = state.rawValue
        let wasSeenToday = isSeenToday(key)
        store.lastPlayed[key] = Date()
        if !wasSeenToday {
            store.daysShown[key, default: 0] += 1
        }
        lastPicked = state
        scheduleSave()
    }

    // MARK: - Selection

    /// Chooses among `candidates`, never repeating the immediately previous
    /// choice and preferring something not yet seen today.
    func pick(from candidates: [BillState]) -> BillState? {
        guard !candidates.isEmpty else { return nil }
        rolloverIfNeeded()

        // Rule 1: drop the one that just played — unless that would leave
        // nothing, in which case repeating is better than falling silent.
        var pool = candidates
        if pool.count > 1, let last = lastPicked {
            pool.removeAll { $0 == last }
        }
        if pool.isEmpty { pool = candidates }

        // Rule 2: anything unseen today wins outright.
        let unseen = pool.filter { !isSeenToday($0.rawValue) }
        if !unseen.isEmpty {
            // Among the unseen, the one that has gone longest without a day
            // on screen goes first, so long-neglected states surface before
            // ones that merely missed today.
            let minDays = unseen.map { store.daysShown[$0.rawValue] ?? 0 }.min() ?? 0
            let starved = unseen.filter { (store.daysShown[$0.rawValue] ?? 0) == minDays }
            return starved.randomElement()
        }
        return pool.randomElement()
    }

    /// Everything in `showcaseable` that has not been on screen yet today,
    /// most-neglected first.
    func unseenToday() -> [BillState] {
        rolloverIfNeeded()
        return Self.showcaseable
            .filter { !isSeenToday($0.rawValue) }
            .sorted { (store.daysShown[$0.rawValue] ?? 0) < (store.daysShown[$1.rawValue] ?? 0) }
    }

    /// How long to wait before showcasing the next unseen animation, paced so
    /// the remaining backlog is spread evenly across the rest of the waking
    /// day rather than dumped in a burst.
    ///
    /// Returns `nil` when there is nothing left to show today.
    func nextCatchUpDelay(now: Date = Date()) -> TimeInterval? {
        let remaining = unseenToday()
        guard !remaining.isEmpty else { return nil }

        let calendar = Calendar.current
        // Aim to be finished by 23:00 — after that the user is likely gone and
        // pacing against midnight just wastes the tail of the day.
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 23
        let deadline = calendar.date(from: components) ?? now.addingTimeInterval(3600)
        let secondsLeft = deadline.timeIntervalSince(now)

        // Past the deadline (or close to it): drain the backlog steadily
        // rather than giving up on it entirely.
        guard secondsLeft > 60 else { return Self.minCatchUpInterval }
        let pace = secondsLeft / Double(remaining.count)
        return min(max(pace, Self.minCatchUpInterval), Self.maxCatchUpInterval)
    }

    /// Reporting surface for the animation-coverage debug view.
    func report() -> [(state: BillState, lastPlayed: Date?, daysShown: Int, seenToday: Bool)] {
        BillState.allCases.map {
            (
                state: $0,
                lastPlayed: store.lastPlayed[$0.rawValue],
                daysShown: store.daysShown[$0.rawValue] ?? 0,
                seenToday: isSeenToday($0.rawValue)
            )
        }
    }

    /// At least this far apart, so a large backlog cannot turn Bill into a
    /// slideshow.
    private static let minCatchUpInterval: TimeInterval = 90
    /// And never so far apart that the backlog can't actually be cleared.
    private static let maxCatchUpInterval: TimeInterval = 20 * 60

    // MARK: - Day handling

    private func isSeenToday(_ key: String) -> Bool {
        guard let date = store.lastPlayed[key] else { return false }
        return Calendar.current.isDateInToday(date)
    }

    private func rolloverIfNeeded() {
        let today = Self.dayFormatter.string(from: Date())
        guard store.lastRolloverDay != today else { return }
        store.lastRolloverDay = today
        // Nothing to clear: "seen today" is derived from `lastPlayed` against
        // the real calendar, so a new day resets it implicitly. Recording the
        // rollover is what lets `daysShown` stay an honest per-day count.
        scheduleSave()
    }

    // MARK: - Persistence

    private var saveWork: DispatchWorkItem?

    /// Coalesced: `record` fires on every clip start, and this file is tiny
    /// but writing it synchronously on the main actor each time is exactly
    /// the pattern that already made `MemoryStore` a main-thread hazard.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.save() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Writes immediately and synchronously — shutdown only, for the same
    /// reason as `MemoryStore.flushNow()`.
    func flushNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        let target = url
        // Off the main actor: the encode is already done, so only the write
        // itself moves, and a dropped write is harmless (the next one wins).
        Task.detached(priority: .utility) {
            try? data.write(to: target, options: .atomic)
        }
    }
}
