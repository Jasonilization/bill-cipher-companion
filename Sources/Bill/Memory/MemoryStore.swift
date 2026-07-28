import Foundation
import Combine

struct MemoryFact: Codable, Identifiable {
    var id = UUID()
    let text: String
    let dateAdded: Date
}

struct MemoryData: Codable {
    var facts: [MemoryFact] = []
    var firstLaunchDate: Date = Date()
    var appOpenCounts: [String: Int] = [:]
}

/// Bill's persisted memory: a small, capped, inspectable JSON file — not an
/// unbounded log. Read by Settings (to show "known you for N days") and
/// available for barks/personality to reference later; writes are explicit,
/// never silent.
@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var data: MemoryData

    private let fileURL: URL
    private static let maxFacts = 50

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
