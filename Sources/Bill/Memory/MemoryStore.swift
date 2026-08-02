import Foundation
import Combine

struct MemoryFact: Codable, Identifiable {
    var id = UUID()
    let text: String
    let dateAdded: Date
}

/// One logged app activation — the raw material `MemoryStore`'s derived
/// properties (previous app, "you keep coming back to this", category
/// tallies) are computed from.
struct AppActivation: Codable {
    let bundleID: String
    let name: String
    let category: String?
    let date: Date
}

struct MemoryData: Codable {
    var facts: [MemoryFact] = []
    var firstLaunchDate: Date = Date()
    var appOpenCounts: [String: Int] = [:]

    // Contextual-awareness additions — all additive, all with defaults, so
    // an existing memory.json from before this pass still decodes fine
    // (Codable synthesis falls back to a property's default when a key is
    // missing, rather than failing the whole decode).
    var appDisplayNames: [String: String] = [:]
    var recentActivations: [AppActivation] = []
    var categoryOpenCounts: [String: Int] = [:]
    var chargingEventCount: Int = 0
    var lowBatteryEventCount: Int = 0
    var cumulativeIdleSeconds: TimeInterval = 0
    var generatedDialogue: [String] = []
    var lastDialogueRefreshDate: Date?

    // App-learning additions — same additive pattern as above.
    /// One-line, ChatGPT-generated descriptions of apps Bill doesn't have a
    /// built-in category for yet (see `CharacterWindowController`'s daily
    /// refresh and `ReactionRouter.handleUncategorizedApp`), keyed by
    /// bundle ID. Learned gradually and locally rather than hardcoded.
    var appDescriptions: [String: String] = [:]
    /// When each bundle ID was first ever seen — lets Bill tell "never seen
    /// this before" apart from "seen it a bunch, still don't know what it
    /// is" for uncategorized apps, without a separate tracking structure.
    var firstSeenDate: [String: Date] = [:]
}

/// Bill's persisted memory: a small, capped, inspectable JSON file — not an
/// unbounded log. Read by Settings (to show "known you for N days"), by
/// `ReactionRouter` (to make dialogue observant of actual usage patterns
/// instead of just the current event), and available for the chat persona
/// preamble. Writes are explicit, never silent.
@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var data: MemoryData

    private let fileURL: URL
    private static let maxFacts = 50
    private static let maxRecentActivations = 60
    private static let maxGeneratedDialogue = 80

    init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Bill", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        fileURL = supportDir.appendingPathComponent("memory.json")

        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(MemoryData.self, from: raw) {
            data = decoded
        } else {
            data = MemoryData()
        }
    }

    var daysKnown: Int {
        max(0, Calendar.current.dateComponents([.day], from: data.firstLaunchDate, to: Date()).day ?? 0)
    }

    var mostOpenedAppBundleID: String? {
        data.appOpenCounts.max(by: { $0.value < $1.value })?.key
    }

    func recordAppOpen(bundleID: String) {
        data.appOpenCounts[bundleID, default: 0] += 1
        save()
    }

    /// The richer form `ReactionRouter` calls now — also logs a recency
    /// entry and a per-category tally, which is what makes "you keep
    /// coming back to this" and "you've been coding a lot today" possible.
    func recordAppOpen(bundleID: String, name: String, category: AppCategory?) {
        data.appOpenCounts[bundleID, default: 0] += 1
        data.appDisplayNames[bundleID] = name
        if data.firstSeenDate[bundleID] == nil {
            data.firstSeenDate[bundleID] = Date()
        }
        if let category {
            data.categoryOpenCounts[category.rawValue, default: 0] += 1
        }
        data.recentActivations.append(AppActivation(bundleID: bundleID, name: name, category: category?.rawValue, date: Date()))
        if data.recentActivations.count > Self.maxRecentActivations {
            data.recentActivations.removeFirst(data.recentActivations.count - Self.maxRecentActivations)
        }
        save()
    }

    /// Whether `bundleID` was recorded for the very first time by the call
    /// to `recordAppOpen` that just returned — checked immediately after,
    /// since `firstSeenDate` itself doesn't otherwise distinguish "just
    /// learned about this" from "learned about this weeks ago."
    func isFirstSighting(of bundleID: String) -> Bool {
        guard let firstSeen = data.firstSeenDate[bundleID] else { return false }
        return Date().timeIntervalSince(firstSeen) < 5
    }

    /// The bundle ID active immediately before the current one — `nil` if
    /// there isn't a distinct previous app yet.
    var previousAppBundleID: String? {
        guard data.recentActivations.count >= 2 else { return nil }
        let currentID = data.recentActivations.last?.bundleID
        for activation in data.recentActivations.dropLast().reversed() where activation.bundleID != currentID {
            return activation.bundleID
        }
        return nil
    }

    func displayName(for bundleID: String) -> String? {
        data.appDisplayNames[bundleID]
    }

    func openCount(for bundleID: String) -> Int {
        data.appOpenCounts[bundleID] ?? 0
    }

    func description(for bundleID: String) -> String? {
        data.appDescriptions[bundleID]
    }

    /// Stores a one-line, ChatGPT-generated description of an
    /// otherwise-uncategorized app — see `CharacterWindowController`'s
    /// daily refresh, which is the only caller.
    func setAppDescription(bundleID: String, _ description: String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        data.appDescriptions[bundleID] = trimmed
        save()
    }

    /// Bundle IDs worth asking ChatGPT to describe on the next daily
    /// refresh: opened often enough to matter (`>= 2` times — a one-off
    /// launch isn't worth spending a description slot on) but still
    /// missing a stored description. Capped by the caller, not here, since
    /// how many to actually ask about per refresh is that caller's call.
    func undescribedFrequentApps(minOpens: Int = 2) -> [(bundleID: String, name: String)] {
        data.appOpenCounts
            .filter { $0.value >= minOpens && data.appDescriptions[$0.key] == nil }
            .compactMap { bundleID, _ in
                data.appDisplayNames[bundleID].map { (bundleID: bundleID, name: $0) }
            }
    }

    /// How many times this app was opened within the last `interval`
    /// seconds — the basis for "you really like this one, don't you?"
    /// without needing an explicit session-tracking system.
    func recentOpenCount(for bundleID: String, within interval: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-interval)
        return data.recentActivations.lazy.filter { $0.bundleID == bundleID && $0.date >= cutoff }.count
    }

    func sessionCount(for category: AppCategory) -> Int {
        data.categoryOpenCounts[category.rawValue] ?? 0
    }

    func recordChargingEvent() {
        data.chargingEventCount += 1
        save()
    }

    func recordLowBatteryEvent() {
        data.lowBatteryEventCount += 1
        save()
    }

    func recordIdleDuration(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        data.cumulativeIdleSeconds += seconds
        save()
    }

    /// A short, human-readable summary of recent activity — handed to
    /// ChatGPT as extra context (see `ChatBridge`'s persona preamble) and
    /// usable for local contextual dialogue too.
    var recentActivitySummary: String {
        let topCategories = data.categoryOpenCounts.sorted { $0.value > $1.value }.prefix(3)
        var parts = topCategories.map { "\($0.key) ×\($0.value)" }
        if data.chargingEventCount > 0 {
            parts.append("charged \(data.chargingEventCount)×")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Growing dialogue library (see CharacterEngine's daily refresh)

    func addGeneratedDialogue(_ lines: [String]) {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        data.generatedDialogue.append(contentsOf: cleaned)
        if data.generatedDialogue.count > Self.maxGeneratedDialogue {
            data.generatedDialogue.removeFirst(data.generatedDialogue.count - Self.maxGeneratedDialogue)
        }
        data.lastDialogueRefreshDate = Date()
        save()
    }

    func shouldRefreshDialogue(interval: TimeInterval) -> Bool {
        guard let last = data.lastDialogueRefreshDate else { return true }
        return Date().timeIntervalSince(last) >= interval
    }

    func addFact(_ text: String) {
        data.facts.append(MemoryFact(text: text, dateAdded: Date()))
        if data.facts.count > Self.maxFacts {
            data.facts.removeFirst(data.facts.count - Self.maxFacts)
        }
        save()
    }

    func reset() {
        data = MemoryData()
        save()
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }
}
