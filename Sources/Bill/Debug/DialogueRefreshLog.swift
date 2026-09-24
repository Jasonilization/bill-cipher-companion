import Foundation

/// One refresh attempt's full record.
///
/// Now `Codable` and persisted (see `DialogueRefreshStore`). It used to be
/// in-memory only, which combined badly with the refresh running silently on a
/// 24-hour timer: by the time you thought to look, the app had been relaunched
/// and there was nothing to see, which is a large part of why the log "didn't
/// work".
struct DialogueRefreshLogEntry: Identifiable, Codable {
    struct AppDescription: Codable, Hashable {
        var name: String
        var description: String
    }

    var id = UUID()
    var date: Date
    var trigger: String
    var prompt: String
    var rawResponse: String?
    var linesAdded: [String] = []
    var appDescriptionsAdded: [AppDescription] = []
    /// `nil` only once the exchange genuinely produced something usable.
    var failureReason: String?
    /// Seconds from send to resolution, so a slow round trip is
    /// distinguishable from a hung one.
    var durationSeconds: Double?

    var succeeded: Bool { failureReason == nil && (!linesAdded.isEmpty || !appDescriptionsAdded.isEmpty) }

    /// One-line, plain-words summary for log strips — the "clear refresh
    /// logs" ask: every entry should read as what happened at a glance.
    var summarized: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let stamp = formatter.string(from: date)
        let headline = linesAdded.first ?? ""
        if let failureReason {
            return "\(stamp) · \(trigger) · FAILED: \(failureReason)"
        }
        if succeeded {
            return "\(stamp) · \(trigger) · OK — \(headline.isEmpty ? "\(appDescriptionsAdded.count) app descriptions" : headline)"
        }
        return "\(stamp) · \(trigger) · nothing landed"
    }
}

/// Observable, persisted store for the refresh log.
///
/// Three defects are fixed by this type existing:
///
/// 1. The log was a plain `var` on a non-observable class, and the view took a
///    plain `let` array — so the window was a snapshot frozen at open time and
///    never updated while a refresh was in flight. Since a refresh takes many
///    seconds, the near-guaranteed experience was "open the log, see a prompt
///    with no response, conclude it is broken."
/// 2. Entries were only appended *after* several early returns, so the most
///    common failures (a jammed refresh, an empty activity summary) produced no
///    entry at all — the log was emptiest exactly when something was wrong.
///    `begin(trigger:prompt:)` is now called on every single attempt.
/// 3. Nothing survived relaunch.
@MainActor
final class DialogueRefreshStore: ObservableObject {
    @Published private(set) var entries: [DialogueRefreshLogEntry] = []

    private let url: URL
    private static let maxEntries = 30

    init(filename: String = "dialogue-refresh-log.json") {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bill", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DialogueRefreshLogEntry].self, from: data) {
            entries = decoded
        }
    }

    /// Records an attempt. Returns its id so the outcome can be attached later.
    @discardableResult
    func begin(trigger: String, prompt: String) -> UUID {
        let entry = DialogueRefreshLogEntry(date: Date(), trigger: trigger, prompt: prompt)
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        save()
        return entry.id
    }

    /// Records an attempt that never got as far as sending anything.
    func recordImmediateFailure(trigger: String, reason: String) {
        var entry = DialogueRefreshLogEntry(date: Date(), trigger: trigger, prompt: "(not sent)")
        entry.failureReason = reason
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        save()
    }

    func finish(
        _ id: UUID,
        rawResponse: String?,
        linesAdded: [String],
        descriptions: [DialogueRefreshLogEntry.AppDescription],
        failureReason: String?
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].rawResponse = rawResponse
        entries[index].linesAdded = linesAdded
        entries[index].appDescriptionsAdded = descriptions
        entries[index].failureReason = failureReason
        entries[index].durationSeconds = Date().timeIntervalSince(entries[index].date)
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let target = url
        Task.detached(priority: .utility) {
            try? data.write(to: target, options: .atomic)
        }
    }
}
