import Foundation

/// The four parts of the day Bill's dialogue varies across.
///
/// Deliberately has **no timer of its own**. `current` is computed on demand
/// and memoised against the window it was derived from, so the hundreds of
/// bark lookups a session makes cost one pair of comparisons each, and the
/// bucket still flips the moment the clock crosses a boundary. (`ClockMonitor`
/// separately announces the *transition*, but nothing depends on it having
/// fired for the right lines to be chosen.)
enum TimeOfDay: String, CaseIterable, Codable, Sendable {
    case morning
    case midday
    case afternoon
    case night

    /// Boundaries, in local hours. Night deliberately spans the wrap at
    /// midnight, which is why the lookup below is written as a descending
    /// ladder rather than a range match.
    ///   05:00–10:59 morning · 11:00–14:59 midday
    ///   15:00–20:59 afternoon · 21:00–04:59 night
    static func bucket(for date: Date, calendar: Calendar = .current) -> TimeOfDay {
        switch calendar.component(.hour, from: date) {
        case 5..<11:  return .morning
        case 11..<15: return .midday
        case 15..<21: return .afternoon
        default:      return .night
        }
    }

    /// The small hours specifically — used by a handful of high-value
    /// triggers (the half-hour chime, the homework nag) that should read
    /// differently at 02:00 than at 22:00. Deliberately *not* a fifth
    /// authoring bucket: quadrupling the dialogue is already a lot of
    /// writing, and quintupling it would mostly produce filler.
    static func isDeadOfNight(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        (1..<5).contains(calendar.component(.hour, from: date))
    }

    var displayName: String {
        switch self {
        case .morning:   return "morning"
        case .midday:    return "midday"
        case .afternoon: return "afternoon"
        case .night:     return "night"
        }
    }
}

@MainActor
enum TimeOfDayCache {
    private static var validUntil: Date = .distantPast
    private static var cached: TimeOfDay = .morning

    /// The current bucket. Recomputed only when the cached one has actually
    /// expired, which is at most once an hour.
    static var current: TimeOfDay {
        let now = Date()
        if now < validUntil { return cached }
        cached = TimeOfDay.bucket(for: now)
        // Valid until the top of the next hour — cheaper than working out the
        // exact next boundary, and wrong by at most one hour of caching, which
        // cannot cross a bucket edge because every edge is on the hour.
        let calendar = Calendar.current
        validUntil = calendar.date(bySetting: .minute, value: 0, of: now.addingTimeInterval(3600))
            ?? now.addingTimeInterval(60)
        return cached
    }
}
