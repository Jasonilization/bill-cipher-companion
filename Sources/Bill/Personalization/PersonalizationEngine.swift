import Foundation

/// Observable state for the personalization setup window (and anything
/// else that wants to watch a run). Classic `ObservableObject`/`@Published`
/// rather than macro-based state wrappers — same reason as
/// `ChatPanelView`'s doc comment: this toolchain's Command Line Tools
/// install can't expand the SwiftUI state macros, and this works.
@MainActor
final class PersonalizationModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case intro
        case generating
        case needsLogin
        case failed(String)
        case finished(apps: Int)
    }

    @Published var phase: Phase = .intro
    @Published var statusText: String = ""
    /// 0…1 across all batches, including the transition request.
    @Published var progress: Double = 0
    @Published var appCount: Int = 0
    @Published var batchIndex: Int = 0
    @Published var batchCount: Int = 0
}

/// The first-run "let Bill study your apps" flow.
///
/// The explicit product ask: personalized dialogue must NOT be pre-written
/// by the developer — the app should, on the user's machine, use its
/// embedded ChatGPT session to *generate* Bill-Cipher-voice Gravity Falls
/// commentary for the user's actual installed apps, bucketed by time of day,
/// plus transition lines for the app pairs they really use.
///
/// Mechanics:
/// - `enumerateApps()` walks /Applications, /System/Applications and
///   ~/Applications (the same surfaces the user actually launches from),
///   prioritized by how often the user *really* opens each one
///   (`MemoryStore.openCount`) so a 200-app disk doesn't dilute the run.
/// - Apps are generated in batches of 8 — small enough that one ChatGPT
///   response can hold 8 apps × 5 lines without truncating or going off
///   format, large enough that a 40-app machine finishes in ~5 requests.
/// - Every request uses the same marker protocol as the daily dialogue
///   refresh, so a stale reply from a previous request is detectable by the
///   missing marker rather than silently parsed.
/// - One extra request covers the transitions for the user's top apps
///   (all ordered pairs, capped) — "one for every transition … or at least
///   the main ones".
/// - Each batch merges into `PersonalizedDialogueStore` the moment it
///   parses, and the store republishes to `DialogueLibrary` immediately, so
///   the commentary is *live* before the whole run finishes. A failure on
///   one batch (timeout, malformed reply) skips to the next rather than
///   killing the run — partial personalization beats none.
@MainActor
final class PersonalizationEngine {
    let model = PersonalizationModel()

    private let memoryStore: MemoryStore
    private let store = PersonalizedDialogueStore.shared

    /// Set by `CharacterWindowController` — the actual send path, which
    /// owns the WebView mounting/watchdog callbacks the bridge needs.
    var send: ((String) -> Void)?
    /// Set by the owning controller — presents the ChatGPT login page
    /// when the embedded session turns out to be signed out.
    var presentLogin: (() -> Void)?
    /// Fired exactly once when a run ends, however it ends (finished,
    /// cancelled, needs-login). The controller uses this for quiet-mode and
    /// roaming teardown — deliberately a callback rather than a Combine
    /// subscription so re-running setup can never stack duplicate
    /// subscriptions.
    var onRunFinished: (() -> Void)?

    /// Set by `CharacterWindowController` — today's weather blurb, so the
    /// generated lines can reference what the sky is actually doing
    /// ("reference today's weather where it genuinely fits").
    var weatherBlurbProvider: (() -> String?)?

    private var apps: [AppCandidate] = []
    private var batches: [[AppCandidate]] = []
    private var transitionPairs: [(from: AppCandidate, to: AppCandidate)] = []
    private var marker: String = ""
    private var pendingBatch: [AppCandidate] = []
    private var pendingTransitions: [(from: AppCandidate, to: AppCandidate)] = []
    private var phase: Phase = .appBatches
    private var timeoutWork: DispatchWorkItem?
    /// The single source of truth for "a run is in flight". Model phase is
    /// presentation state; this is control state — the two must not be
    /// entangled or `finish()` becomes recursive.
    private var isRunning = false

    private enum Phase {
        case appBatches
        case transitions
        case done
    }

    struct AppCandidate: Equatable {
        let bundleID: String
        let name: String
    }

    private static let appsPerBatch = 8
    private static let maxApps = 40
    private static let transitionAppCount = 6
    private static let perRequestTimeout: TimeInterval = 120
    /// A line beyond this reads as a wall of text in the bark bubble and is
    /// far more likely to have drifted off-format.
    private static let maxLineLength = 160

    init(memoryStore: MemoryStore) {
        self.memoryStore = memoryStore
    }

    var isActive: Bool { isRunning }

    // MARK: - Run control

    func begin() {
        guard !isRunning else { return }
        isRunning = true
        apps = Self.enumerateApps(prioritizingOn: memoryStore)
        batches = stride(from: 0, to: apps.count, by: Self.appsPerBatch).map {
            Array(apps[$0..<min($0 + Self.appsPerBatch, apps.count)])
        }
        transitionPairs = Self.pairs(among: Array(apps.prefix(Self.transitionAppCount)))
        model.appCount = apps.count
        model.batchCount = batches.count + (transitionPairs.isEmpty ? 0 : 1)
        model.batchIndex = 0
        model.progress = 0
        if batches.isEmpty {
            finish()
            return
        }
        model.phase = .generating
        phase = .appBatches
        requestNext()
    }

    func cancel() {
        timeoutWork?.cancel()
        timeoutWork = nil
        isRunning = false
        phase = .done
        model.phase = .failed("Cancelled.")
        onRunFinished?()
    }

    /// A reply from the ChatGPT page. `nil`/empty or a missing marker means
    /// the batch failed — skip forward, don't stall the run.
    func handleResponse(_ raw: String?) {
        timeoutWork?.cancel()
        timeoutWork = nil
        defer {
            if isRunning {
                requestNext()
            }
        }

        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        guard text.hasPrefix(marker) else { return }
        text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)

        switch phase {
        case .appBatches:
            parseAppBatch(text)
        case .transitions:
            parseTransitions(text)
        case .done:
            break
        }
    }

    private func requestNext() {
        guard isRunning else { return }
        switch phase {
        case .appBatches:
            guard !batches.isEmpty else {
                advanceToTransitions()
                return
            }
            pendingBatch = batches.removeFirst()
            marker = Self.freshMarker()
            model.batchIndex += 1
            model.statusText = "Writing quips for \(pendingBatch.map(\.name).prefix(3).joined(separator: ", "))…"
            send?(Self.appBatchPrompt(for: pendingBatch, marker: marker, weather: weatherBlurbProvider?()))
            armTimeout()
        case .transitions:
            guard !transitionPairs.isEmpty else {
                finish()
                return
            }
            pendingTransitions = transitionPairs
            transitionPairs = []
            marker = Self.freshMarker()
            model.batchIndex += 1
            model.statusText = "Writing transition lines…"
            send?(Self.transitionPrompt(for: pendingTransitions, marker: marker, weather: weatherBlurbProvider?()))
            armTimeout()
        case .done:
            break
        }
    }

    private func advanceToTransitions() {
        if transitionPairs.isEmpty {
            finish()
        } else {
            phase = .transitions
            requestNext()
        }
    }

    private func armTimeout() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.statusText = "One request went quiet — moving on."
            if self.isRunning {
                self.requestNext()
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.perRequestTimeout, execute: work)
    }

    private func finish() {
        timeoutWork?.cancel()
        timeoutWork = nil
        isRunning = false
        phase = .done
        let personalized = store.appCount
        model.progress = 1
        model.phase = .finished(apps: personalized)
        onRunFinished?()
    }

    /// Called by the owning controller when the ChatGPT session turns out
    /// to be signed out mid-run.
    func requireLogin() {
        timeoutWork?.cancel()
        timeoutWork = nil
        isRunning = false
        phase = .done
        model.phase = .needsLogin
        presentLogin?()
        onRunFinished?()
    }

    private static func freshMarker() -> String {
        "BILL-\(Int.random(in: 100000...999999))"
    }

    // MARK: - Enumeration

    /// Every launchable app the user actually has, most-used first. Bundle
    /// IDs are deduped so an app present in both /Applications and a
    /// subfolder counts once, and `LSUIElement` agents (menu-bar helpers)
    /// are skipped — they never get an activation event to comment on.
    static func enumerateApps(prioritizingOn memoryStore: MemoryStore) -> [AppCandidate] {
        var seen = Set<String>()
        var result: [AppCandidate] = []
        let fileManager = FileManager.default
        let roots = [
            "/System/Applications",
            NSHomeDirectory() + "/Applications",
            "/Applications",
        ]
        for root in roots {
            guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".app") else { continue }
                // Depth cap: /Applications/Utilities/Thing.app is fine;
                // spelunking through nested helper bundles is pointless.
                guard relative.filter { $0 == "/" }.count <= 2 else { continue }
                let path = (root as NSString).appendingPathComponent(relative)
                guard
                    let bundle = Bundle(path: path),
                    let bundleID = bundle.bundleIdentifier,
                    !bundleID.isEmpty,
                    let info = bundle.infoDictionary
                else { continue }
                guard (info["LSUIElement"] as? Bool) != true else { continue }
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info[kCFBundleNameKey as String] as? String)
                    ?? relative
                guard !seen.contains(bundleID) else { continue }
                seen.insert(bundleID)
                result.append(AppCandidate(bundleID: bundleID, name: name))
            }
        }
        result.sort { lhs, rhs in
            let lhsCount = memoryStore.openCount(for: lhs.bundleID)
            let rhsCount = memoryStore.openCount(for: rhs.bundleID)
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.name < rhs.name
        }
        return Array(result.prefix(maxApps))
    }

    /// All ordered pairs among `apps` — "from A to B" reads differently
    /// from "from B to A", and the user asked for the *specific* pairs.
    private static func pairs(among apps: [AppCandidate]) -> [(from: AppCandidate, to: AppCandidate)] {
        var result: [(from: AppCandidate, to: AppCandidate)] = []
        for from in apps {
            for to in apps where to != from {
                result.append((from, to))
            }
        }
        return result
    }

    // MARK: - Prompts

    /// The persona preamble shared by every request. Every clause is
    /// load-bearing: ALL CAPS is how the pixel bark font renders anyway,
    /// the lore list keeps references canon, "one per line" plus the exact
    /// `KEY|VALUE` shape keeps the reply parseable, and "90 characters"
    /// keeps the bark bubble readable.
    private static func personaPreamble(marker: String, weather: String?) -> String {
        var preamble = """
        \(marker)
        You write dialogue for BILL CIPHER, the triangular dream demon from \
        Gravity Falls, living as a desktop companion on a Mac. Voice: \
        theatrical, ALL CAPS, menacing-but-fond of this user, deal-pitching \
        energy. Reference actual Gravity Falls lore where it genuinely fits \
        — the Mystery Shack, Pine Tree, Shooting Star, Soos, the journals, \
        Ford, Stan, Gideon, the gnomes, Blendin, Time Baby, Weirdmageddon, \
        the Zodiac wheel, the bunker, Summerween, the Manotaurs, the \
        Multi-Bear. Each line must contain a specific canon nod or in-joke, \
        not just the show's name. Lines must be under 90 characters, in \
        English, and work standalone with no numbering or quotes. Respond \
        with ONLY the lines, one per line, in the exact formats given, and \
        begin your reply with \(marker) on its own line.
        """
        if let weather, !weather.isEmpty {
            preamble += "\nToday outside the user's window: \(weather). "
            preamble += "Reference today's weather in a few of the lines where it genuinely fits — not all of them."
        }
        return preamble
    }

    private static func appBatchPrompt(for apps: [AppCandidate], marker: String, weather: String?) -> String {
        var prompt = personaPreamble(marker: marker, weather: weather)
        prompt += """

        For EACH app below, write FOUR lines about the user opening that \
        app — one for MORNING, one for MIDDAY, one for AFTERNOON, one for \
        NIGHT (the line should make sense at that time) — plus ONE short \
        description of what the app is, in Bill's voice, under 70 \
        characters. Format each EXACTLY, one per line:
        APP|<BUNDLE_ID>|<MORNING|MIDDAY|AFTERNOON|NIGHT>|<line>
        DESC|<BUNDLE_ID>|<description>

        Apps:
        \(apps.map { "- \($0.name) (\($0.bundleID))" }.joined(separator: "\n"))
        """
        return prompt
    }

    private static func transitionPrompt(for pairs: [(from: AppCandidate, to: AppCandidate)], marker: String, weather: String?) -> String {
        var prompt = personaPreamble(marker: marker, weather: weather)
        prompt += """

        For EACH ordered pair below, write ONE line about the user \
        switching from the first app to the second. Format each EXACTLY, \
        one per line:
        TRANS|<FROM_BUNDLE_ID>|<TO_BUNDLE_ID>|<line>

        Pairs:
        \(pairs.map { "- \($0.from.name) to \($0.to.name) (\($0.from.bundleID) to \($0.to.bundleID))" }.joined(separator: "\n"))
        """
        return prompt
    }

    // MARK: - Parsing

    private func parseAppBatch(_ text: String) {
        let expected = Set(pendingBatch.map(\.bundleID))
        var linesParsed = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "APP" where fields.count == 4:
                let (_, bundleID, bucket, line) = (fields[0], fields[1], fields[2], fields[3])
                guard expected.contains(bundleID), Self.isValidBucket(bucket) else { continue }
                let cleaned = line.trimmingCharacters(in: .whitespaces)
                guard !cleaned.isEmpty, cleaned.count <= Self.maxLineLength else { continue }
                store.mergeAppLines(bundleID: bundleID, bucket: bucket.lowercased(), lines: [cleaned])
                linesParsed += 1
            case "DESC" where fields.count == 3:
                let (_, bundleID, description) = (fields[0], fields[1], fields[2])
                guard expected.contains(bundleID) else { continue }
                let cleaned = description.trimmingCharacters(in: .whitespaces)
                guard !cleaned.isEmpty, cleaned.count <= 100 else { continue }
                store.mergeDescription(bundleID: bundleID, description: cleaned)
            default:
                continue
            }
        }
        pendingBatch = []
        if linesParsed > 0 {
            store.publishToDialogueLibrary()
            model.statusText = "Studied \(linesParsed) lines' worth of apps."
        }
        model.progress = Double(model.batchIndex) / Double(max(1, model.batchCount))
    }

    private func parseTransitions(_ text: String) {
        let ids = Set(apps.map(\.bundleID))
        var parsed = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[0] == "TRANS",
                  ids.contains(fields[1]), ids.contains(fields[2]) else { continue }
            let cleaned = fields[3].trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, cleaned.count <= Self.maxLineLength else { continue }
            store.mergeTransition(fromBundleID: fields[1], toBundleID: fields[2], lines: [cleaned])
            parsed += 1
        }
        pendingTransitions = []
        if parsed > 0 {
            store.publishToDialogueLibrary()
            model.statusText = "Learned \(parsed) switcheroo lines."
        }
        model.progress = Double(model.batchIndex) / Double(max(1, model.batchCount))
    }

    private static func isValidBucket(_ bucket: String) -> Bool {
        ["morning", "midday", "afternoon", "night"].contains(bucket.lowercased())
    }
}
