import Foundation

/// One trigger's worth of dialogue, split by time of day.
///
/// `any` holds lines that work at any hour; the four bucket arrays hold lines
/// that only make sense at that time. Every pool is legal partially authored —
/// a bucket left empty simply contributes nothing.
struct DialoguePool: Codable, Sendable, Equatable {
    var any: [String] = []
    var morning: [String] = []
    var midday: [String] = []
    var afternoon: [String] = []
    var night: [String] = []

    init(any: [String] = [], morning: [String] = [], midday: [String] = [],
         afternoon: [String] = [], night: [String] = []) {
        self.any = any
        self.morning = morning
        self.midday = midday
        self.afternoon = afternoon
        self.night = night
    }

    func bucket(_ time: TimeOfDay) -> [String] {
        switch time {
        case .morning:   return morning
        case .midday:    return midday
        case .afternoon: return afternoon
        case .night:     return night
        }
    }

    /// The lines eligible right now.
    ///
    /// Time-specific lines are returned **alone** when the bucket has any,
    /// rather than being pooled with `any`. That is the whole point: with a
    /// typical pool of 10 generic lines and 3 night-specific ones, merging
    /// them would make the night flavour show up under a quarter of the time
    /// and the time-of-day variation would be barely perceptible. Merging
    /// only happens when the bucket is too thin to carry the pool on its own.
    func lines(for time: TimeOfDay) -> [String] {
        let specific = bucket(time)
        if specific.count >= Self.standaloneBucketThreshold { return specific }
        if specific.isEmpty { return any }
        return specific + any
    }

    /// Below this a bucket is treated as flavour to blend in rather than a
    /// pool in its own right — three lines on repeat is more grating than
    /// occasionally hearing a generic one.
    private static let standaloneBucketThreshold = 3

    var isEmpty: Bool {
        any.isEmpty && morning.isEmpty && midday.isEmpty && afternoon.isEmpty && night.isEmpty
    }

    var lineCount: Int {
        any.count + morning.count + midday.count + afternoon.count + night.count
    }

    /// Folds another pool in, de-duplicating and capping each bucket.
    mutating func merge(_ other: DialoguePool, cappingBucketsAt cap: Int) {
        func combine(_ lhs: [String], _ rhs: [String]) -> [String] {
            var seen = Set(lhs.map { $0.lowercased() })
            var result = lhs
            for line in rhs where !seen.contains(line.lowercased()) {
                seen.insert(line.lowercased())
                result.append(line)
            }
            return Array(result.suffix(cap))
        }
        any = combine(any, other.any)
        morning = combine(morning, other.morning)
        midday = combine(midday, other.midday)
        afternoon = combine(afternoon, other.afternoon)
        night = combine(night, other.night)
    }
}
