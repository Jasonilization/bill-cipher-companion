import Foundation

/// Single source of truth for everything Bill can say.
///
/// Lines live in `Resources/Dialogue/dialogue.json` rather than in Swift
/// source. That is not a style preference — ChatGPT-generated lines have to
/// merge into the same key space at runtime, so a runtime dictionary is
/// required either way. Sourcing the static half from JSON as well means one
/// lookup path instead of two, no recompile to tweak a line, and a readable
/// diff when a few hundred lines change at once.
///
/// Compile-time safety is not lost: `DialogueKey` is a closed enum, and
/// `missingKeys()` reports any key with no authored content so a typo shows up
/// as a reported gap rather than as Bill silently saying nothing.
@MainActor
final class DialogueLibrary {
    static let shared = DialogueLibrary()

    enum LoadState: Equatable {
        case notLoaded
        case loaded(pools: Int, lines: Int)
        case failed(String)
    }

    private(set) var loadState: LoadState = .notLoaded

    /// Authored content, keyed by `DialogueKey.rawValue` (plus the handful of
    /// free-form keys like `battery.35`).
    private var pools: [String: DialoguePool] = [:]
    /// Lines learned from ChatGPT, kept separate so a refresh can replace them
    /// wholesale without touching the authored set.
    private var generated: [String: DialoguePool] = [:]
    /// Lines personalized to *this user's* apps by the first-run setup flow
    /// (`PersonalizationEngine` → `PersonalizedDialogueStore`), under their
    /// own `papp.` / `ptransapp.` key family. Kept separate from `generated`
    /// because the daily refresh replaces *that* dictionary wholesale and
    /// must not nuke the personalization.
    private var personalized: [String: DialoguePool] = [:]
    /// Last line returned per key, so a pool never repeats itself back-to-back.
    private var lastLine: [String: String] = [:]

    /// Chance that an eligible generated line is preferred over an authored
    /// one, when the key has both. Low enough that Bill's authored voice stays
    /// dominant, high enough that a refresh is actually noticeable — the old
    /// behaviour surfaced generated lines on roughly 3.75% of wander beats,
    /// which is why they read as "not implemented".
    private static let generatedBlend = 0.3

    // MARK: - Loading

    /// Decodes the bundled JSON. Cheap (single-digit milliseconds for a few
    /// thousand short strings) but still done off the launch critical path by
    /// `AppDelegate`.
    func warmUp() {
        guard case .notLoaded = loadState else { return }
        guard let url = Bundle.module.url(forResource: "dialogue", withExtension: "json", subdirectory: "Dialogue") else {
            loadState = .failed("dialogue.json not found in bundle")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            pools = try JSONDecoder().decode([String: DialoguePool].self, from: data)
            loadState = .loaded(pools: pools.count, lines: pools.values.reduce(0) { $0 + $1.lineCount })
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    /// Replaces the generated half. Called after a successful dialogue refresh.
    func setGenerated(_ new: [String: DialoguePool]) {
        generated = new
    }

    /// Replaces the personalized half. Called by
    /// `PersonalizedDialogueStore.publishToDialogueLibrary` at launch and
    /// after each setup-flow batch lands.
    func setPersonalized(_ new: [String: DialoguePool]) {
        personalized = new
    }

    var generatedLineCount: Int {
        generated.values.reduce(0) { $0 + $1.lineCount }
    }

    // MARK: - Lookup

    /// A resolved line for `key`, or `nil` if nothing is authored for it.
    ///
    /// `substitutions` fills `{token}` placeholders. `{app}` and
    /// `{description}` are the historical two; new triggers add their own
    /// (`{pct}`, `{time}`, `{minutes}`) without needing a new overload.
    func line(
        _ key: String,
        at time: TimeOfDay? = nil,
        substitutions: [String: String] = [:]
    ) -> String? {
        let bucket = time ?? TimeOfDayCache.current

        // Personalized lines are the *point* of their key — the router only
        // reaches a `papp.`/`ptransapp.` key when it decided this app
        // deserves one — so they win their key outright rather than blending
        // into the authored pool the way daily-refresh lines do.
        if let personal = personalized[key]?.lines(for: bucket), !personal.isEmpty {
            let chosen = Self.pick(personal, avoiding: lastLine[key])
            lastLine[key] = chosen
            return Self.resolve(chosen, substitutions: substitutions)
        }

        var candidates = pools[key]?.lines(for: bucket) ?? []
        let generatedCandidates = generated[key]?.lines(for: bucket) ?? []
        if !generatedCandidates.isEmpty,
           candidates.isEmpty || Double.random(in: 0..<1) < Self.generatedBlend {
            candidates = generatedCandidates
        }
        guard !candidates.isEmpty else { return nil }

        // Never the same line twice in a row from the same key.
        var pool = candidates
        if pool.count > 1, let previous = lastLine[key] {
            pool.removeAll { $0 == previous }
        }
        guard let chosen = pool.randomElement() ?? candidates.randomElement() else { return nil }
        lastLine[key] = chosen

        return Self.resolve(chosen, substitutions: substitutions)
    }

    func line(
        _ key: DialogueKey,
        at time: TimeOfDay? = nil,
        substitutions: [String: String] = [:]
    ) -> String? {
        line(key.rawValue, at: time, substitutions: substitutions)
    }

    /// Tries each key in order and returns the first that has content — the
    /// fallback ladder used by app transitions (exact pair → category pair →
    /// generic) and by the clock (`clock.2130` → `clock.night`).
    func firstLine(
        _ keys: [String],
        at time: TimeOfDay? = nil,
        substitutions: [String: String] = [:]
    ) -> String? {
        for key in keys {
            if let resolved = line(key, at: time, substitutions: substitutions) { return resolved }
        }
        return nil
    }

    static func resolve(_ template: String, substitutions: [String: String]) -> String {
        guard template.contains("{") else { return template }
        var result = template
        for (token, value) in substitutions {
            result = result.replacingOccurrences(of: "{\(token)}", with: value)
        }
        return result
    }

    /// Picks a random line, avoiding the last one served from this key when
    /// there is any other option — the same no-repeat rule the main lookup
    /// path applies, factored out so the personalized branch shares it.
    private static func pick(_ lines: [String], avoiding last: String?) -> String {
        var pool = lines
        if pool.count > 1, let last, !last.isEmpty {
            pool.removeAll { $0 == last }
        }
        return pool.randomElement() ?? lines[0]
    }

    // MARK: - Reporting

    func has(_ key: String) -> Bool {
        !(pools[key]?.isEmpty ?? true) || !(generated[key]?.isEmpty ?? true)
    }

    /// Every `DialogueKey` with no authored content — surfaced in the debug
    /// report so an unwired key is visible instead of silent.
    func missingKeys() -> [DialogueKey] {
        DialogueKey.allCases.filter { pools[$0.rawValue]?.isEmpty ?? true }
    }

    func report() -> [(key: String, any: Int, morning: Int, midday: Int, afternoon: Int, night: Int, generated: Int)] {
        var keys = Set(pools.keys)
        keys.formUnion(generated.keys)
        keys.formUnion(personalized.keys)
        return keys.sorted().map { key in
            let p = pools[key] ?? DialoguePool()
            return (
                key: key,
                any: p.any.count,
                morning: p.morning.count,
                midday: p.midday.count,
                afternoon: p.afternoon.count,
                night: p.night.count,
                generated: generated[key]?.lineCount ?? 0
            )
        }
    }

    // MARK: - Quotes Manager support

    /// Total lines reachable under `key` right now, across all three
    /// sources (authored, daily-refresh generated, personalized).
    func totalLines(for key: String) -> Int {
        (pools[key]?.lineCount ?? 0)
            + (generated[key]?.lineCount ?? 0)
            + (personalized[key]?.lineCount ?? 0)
    }

    /// Which sources feed `key`, for the manager's A/G/P badges.
    func sourceCounts(for key: String) -> (authored: Int, generated: Int, personalized: Int) {
        (
            pools[key]?.lineCount ?? 0,
            generated[key]?.lineCount ?? 0,
            personalized[key]?.lineCount ?? 0
        )
    }

    /// Every line under `key`, bucket by bucket, tagged with its source —
    /// the quotes manager's detail pane.
    func poolDetail(_ key: String) -> [(bucket: String, source: String, line: String)] {
        var result: [(String, String, String)] = []
        let buckets: [(String, (DialoguePool) -> [String])] = [
            ("any", { $0.any }),
            ("morning", { $0.morning }),
            ("midday", { $0.midday }),
            ("afternoon", { $0.afternoon }),
            ("night", { $0.night }),
        ]
        for (name, slice) in buckets {
            for line in slice(pools[key] ?? DialoguePool()) {
                result.append((name, "authored", line))
            }
            for line in slice(generated[key] ?? DialoguePool()) {
                result.append((name, "generated", line))
            }
            for line in slice(personalized[key] ?? DialoguePool()) {
                result.append((name, "personalized", line))
            }
        }
        return result
    }
}
