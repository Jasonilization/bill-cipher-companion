import Foundation

/// "Hey, go do homework for once." / "You're missing out on..."
///
/// **Adds no timer of its own.** It is driven entirely by the half-hour chime
/// that `ClockMonitor` already produces, so the whole feature costs nothing at
/// rest — a nag is just a decision made on a tick that was going to happen
/// anyway.
///
/// Deliberately conservative about *when* it is allowed to speak, because a
/// nagging desktop pet stops being funny very quickly:
///
/// - Never before `earliestHour` — being told off about homework at 07:00 is
///   just rude, and there has been no day yet in which to have done it.
/// - Never when the machine has barely been used (`minimumActivity`) — "you
///   did no homework" is a fair observation after four hours of gaming and an
///   unfair one after you opened the lid to check the time.
/// - At most `maxPerDay`, and never two in a row about the same thing.
@MainActor
final class HabitNagger {
    private let memoryStore: MemoryStore
    /// Emits the dialogue key to speak.
    var onNag: ((String) -> Void)?

    private var nagsToday = 0
    private var nagDay = ""
    private var lastNagKey: String?
    private var lastNagAt: Date?

    /// Nothing before mid-afternoon: by then a school day has actually
    /// happened and the observation is fair.
    private static let earliestHour = 15
    /// And nothing in the small hours — at 02:00 the useful message is "sleep",
    /// which the clock chime already says.
    private static let latestHour = 23
    private static let maxPerDay = 2
    private static let minimumGap: TimeInterval = 3 * 60 * 60
    /// Below this many app activations the day is too quiet to judge.
    private static let minimumActivity = 12

    init(memoryStore: MemoryStore) {
        self.memoryStore = memoryStore
    }

    /// Called from the half-hour chime.
    func considerNagging(now: Date = Date()) {
        rolloverIfNeeded(now: now)

        let hour = Calendar.current.component(.hour, from: now)
        guard (Self.earliestHour...Self.latestHour).contains(hour) else { return }
        guard nagsToday < Self.maxPerDay else { return }
        if let last = lastNagAt, now.timeIntervalSince(last) < Self.minimumGap { return }
        guard memoryStore.totalActivationsToday() >= Self.minimumActivity else { return }

        guard let key = chooseNag() else { return }
        nagsToday += 1
        lastNagAt = now
        lastNagKey = key
        onNag?(key)
    }

    /// Picks what is most worth saying, preferring not to repeat the last one.
    private func chooseNag() -> String? {
        var candidates: [String] = []

        // "Productivity" is where docs/slides/notes/school-portal apps live, so
        // it is the closest honest proxy for "did any schoolwork happen".
        if memoryStore.count(of: .productivity) == 0 {
            candidates.append("nag.homework")
        }
        // Duolingo and friends also land in productivity, so a separate
        // education nag only makes sense once *some* productivity happened but
        // it was clearly all documents.
        if memoryStore.count(of: .productivity) > 0, memoryStore.count(of: .creative) == 0 {
            candidates.append("nag.education")
        }
        // All work and no chaos.
        if memoryStore.count(of: .gaming) == 0, memoryStore.count(of: .music) == 0 {
            candidates.append("nag.fun")
        }

        guard !candidates.isEmpty else { return nil }
        if candidates.count > 1, let last = lastNagKey {
            candidates.removeAll { $0 == last }
        }
        return candidates.randomElement()
    }

    private func rolloverIfNeeded(now: Date) {
        let today = MemoryStore.dayFormatter.string(from: now)
        guard nagDay != today else { return }
        nagDay = today
        nagsToday = 0
        lastNagKey = nil
        lastNagAt = nil
    }
}
