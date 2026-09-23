import Foundation

/// Persists the personalized, ChatGPT-generated half of Bill's dialogue:
/// per-app quips for each time of day, a one-line description per app, and
/// transition lines for the user's *own* app pairs.
///
/// This is deliberately a separate file from `MemoryStore` (which owns
/// *observed* facts about the user) — generated *speech* has a different
/// lifecycle: it is produced by the first-run setup flow
/// (`PersonalizationEngine`), can be regenerated wholesale, and merges into
/// the dialogue lookup under its own key family rather than the authored
/// pools.
///
/// Keys surfaced to `DialogueLibrary`:
/// - `papp.<bundleID>` — lines for when that app is activated, bucketed by
///   time of day exactly like an authored pool.
/// - `ptransapp.<fromBundleID>-><toBundleID>` — a line for switching from
///   one specific app to another, tried *before* the authored
///   category-pair ladder in `ReactionRouter.handleFirstOpen`.
@MainActor
final class PersonalizedDialogueStore {
    static let shared = PersonalizedDialogueStore()

    // MARK: - Model

    private struct Payload: Codable {
        var generatedAt: Date?
        var appLines: [String: DialoguePool] = [:]
        var appDescriptions: [String: String] = [:]
        /// Keyed `"fromBundle->toBundle"`.
        var transitions: [String: [String]] = [:]
    }

    private var payload: Payload
    private let fileURL: URL

    private static let maxLinesPerBucket = 3
    static let appKeyPrefix = "papp."
    static let transitionKeyPrefix = "ptransapp."

    var generatedAt: Date? { payload.generatedAt }
    var isPersonalized: Bool {
        !payload.appLines.values.allSatisfy(\.isEmpty)
    }
    var appCount: Int {
        payload.appLines.values.filter { !$0.isEmpty }.count
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("Bill", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("PersonalizedDialogue.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
        } else {
            payload = Payload()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Access

    func description(for bundleID: String) -> String? {
        payload.appDescriptions[bundleID]
    }

    func appKey(for bundleID: String) -> String {
        Self.appKeyPrefix + bundleID
    }

    func transitionKey(from: String, to: String) -> String {
        Self.transitionKeyPrefix + "\(from)->\(to)"
    }

    // MARK: - Writing (called by `PersonalizationEngine` as batches land)

    /// Merges one app's freshly generated lines. Buckets are capped so a
    /// re-run of setup can never balloon a pool into Groundhog Day.
    func mergeAppLines(bundleID: String, bucket: String, lines: [String]) {
        var pool = payload.appLines[bundleID] ?? DialoguePool()
        var target: [String] {
            get {
                switch bucket {
                case "morning": return pool.morning
                case "midday": return pool.midday
                case "afternoon": return pool.afternoon
                case "night": return pool.night
                default: return pool.any
                }
            }
            set {
                switch bucket {
                case "morning": pool.morning = newValue
                case "midday": pool.midday = newValue
                case "afternoon": pool.afternoon = newValue
                case "night": pool.night = newValue
                default: pool.any = newValue
                }
            }
        }
        var seen = Set(target.map { $0.lowercased() })
        for line in lines where !seen.contains(line.lowercased()) {
            seen.insert(line.lowercased())
            target.append(line)
        }
        target = Array(target.suffix(Self.maxLinesPerBucket))
        payload.appLines[bundleID] = pool
        save()
    }

    func mergeDescription(bundleID: String, description: String) {
        payload.appDescriptions[bundleID] = description
        save()
    }

    func mergeTransition(fromBundleID: String, toBundleID: String, lines: [String]) {
        let key = "\(fromBundleID)->\(toBundleID)"
        var existing = payload.transitions[key] ?? []
        for line in lines where !existing.contains(line) {
            existing.append(line)
        }
        payload.transitions[key] = Array(existing.suffix(Self.maxLinesPerBucket))
        save()
    }

    // MARK: - DialogueLibrary bridge

    /// The whole store as `DialogueLibrary` pools, ready for
    /// `setPersonalized`. A fresh convert every call is fine — this runs
    /// once per setup batch, not per lookup.
    func dialoguePools() -> [String: DialoguePool] {
        var result: [String: DialoguePool] = [:]
        for (bundleID, pool) in payload.appLines where !pool.isEmpty {
            result[Self.appKeyPrefix + bundleID] = pool
        }
        for (pair, lines) in payload.transitions where !lines.isEmpty {
            result[Self.transitionKeyPrefix + pair] = DialoguePool(any: lines)
        }
        return result
    }

    /// Pushes the current content into the live library. Called at launch
    /// (after `warmUp`) and after each generation batch.
    func publishToDialogueLibrary() {
        DialogueLibrary.shared.setPersonalized(dialoguePools())
    }
}
