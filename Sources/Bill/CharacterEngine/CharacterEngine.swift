import Foundation

/// Bill's behavior brain — separate from both the renderer (`Animation/`)
/// and the AI chat system. Decides *when* Bill should be in a given state:
/// idle-variety boredom beats, occasional personality flourishes, and rare
/// Easter eggs while genuinely idle; the system monitor and chat bridge
/// call `request(_:)` the same way for everything else.
@MainActor
final class CharacterEngine {
    let rig: BillRigNode
    let stateMachine: BillStateMachine

    private var idleBeatTimer: Timer?
    private var catchUpTimer: Timer?
    private var isRunning = false
    private var lastRareEventDate: Date?

    /// Tracks what has been on screen today so nothing in the library goes
    /// unseen, and so a random choice never repeats itself back-to-back.
    let coverage = AnimationCoverage()

    /// Divides the delay between idle beats — set by `AppDelegate` from
    /// `AppPreferences.speakingFrequency` and kept live via a Combine
    /// subscription there. Above 1.0 means shorter delays (chattier), below
    /// means longer ones (quieter); a divisor rather than a multiplier so
    /// "bigger number on the slider" reads as "more frequent," matching the
    /// slider's intent rather than its literal arithmetic.
    var speakingFrequencyMultiplier: Double = 1.0

    /// Multiplies the *spacing* between ambient idle beats — the Settings
    /// "how long until the next animation" knob, kept live from
    /// `AppPreferences.ambientAnimationSpacing` the same way as above.
    /// Deliberately its own control: pacing his motion should not drag his
    /// dialogue (or vice versa) along with it.
    var ambientAnimationSpacingMultiplier: Double = 1.0

    /// Rare Easter eggs (power surge / zodiac vision / summon ritual / …)
    /// are deliberately dramatic — see `BillState.rareEasterEggs` — so
    /// they're gated to a small chance per idle beat *and* a cooldown,
    /// rather than ever showing up back-to-back.
    /// Raised from 0.03. With the ambient-chatter branch gone, the idle beat
    /// is now purely about *animation* variety, so there is no longer any
    /// reason to keep the dramatic states this rare — at the old rate a given
    /// Easter egg surfaced roughly once every two and a half hours of
    /// uninterrupted idling, which is why so much of the library was never
    /// actually seen.
    private static let rareEventChance = 0.10
    private static let rareEventCooldown: TimeInterval = 3 * 60

    init() {
        rig = BillRigNode.build()
        stateMachine = BillStateMachine(rig: rig)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Kicks off the continuous idle bob (see `BillStateMachine.init`'s
        // doc comment for why this can't happen at construction time) so
        // Bill is already gently moving before the very first idle beat,
        // rather than sitting frozen for the first 4-9s.
        stateMachine.request(.idle)
        stateMachine.onClipStarted = { [weak self] state in self?.coverage.record(state) }
        scheduleNextIdleBeat()
        scheduleNextCatchUp()
    }

    func stop() {
        isRunning = false
        idleBeatTimer?.invalidate()
        idleBeatTimer = nil
        catchUpTimer?.invalidate()
        catchUpTimer = nil
    }

    /// Entry point for reactions: chat bridge, system monitor, debug menu.
    func request(_ state: BillState, force: Bool = false) {
        stateMachine.request(state, force: force)
    }

    /// How much a given line matters, which is what decides whether the
    /// speaking-frequency preference is allowed to swallow it.
    enum BarkImportance {
        /// Ordinary contextual commentary. Suppressed proportionally as the
        /// speaking-frequency slider comes down.
        case normal
        /// Things the user asked to be told: study-mode enforcement, a
        /// critical battery, the half-hour chime. Never suppressed.
        case always
    }

    /// Shows a bark line above Bill's head without necessarily changing his
    /// animation state.
    ///
    /// The speaking-frequency preference used to affect exactly one thing —
    /// the *delay between idle beats* — which meant turning it down made Bill
    /// less animated without making him meaningfully quieter, while every
    /// app/system reaction kept firing at full rate. Now that the
    /// non-contextual ambient chatter is gone and everything Bill says is
    /// tied to something that actually happened, the preference does the job
    /// its name implies: it is the probability that an ordinary contextual
    /// line is spoken at all.
    func bark(_ text: String, importance: BarkImportance = .normal) {
        guard !text.isEmpty else { return }
        if importance == .normal, !shouldSpeak() { return }
        stateMachine.showBark(text)
    }

    /// At the default of 1.0 every ordinary line is spoken; at the slider's
    /// minimum of 0.25 roughly a quarter are.
    func shouldSpeak() -> Bool {
        let probability = min(1.0, max(0.0, speakingFrequencyMultiplier))
        return Double.random(in: 0..<1) < probability
    }

    private func scheduleNextIdleBeat() {
        idleBeatTimer?.invalidate()
        let baseDelay = Double.random(in: 4...9)
        // Spacing knob first (motion pacing), frequency knob second (line
        // probability now lives entirely in `shouldSpeak`, but the beat
        // cadence still respects overall chattiness when the user leans on
        // it hard). The hold extension guarantees a just-started clip
        // finishes before the next beat fires ("not playing long enough").
        let hold = pendingBeatExtension ?? 0
        pendingBeatExtension = nil
        let delay = max(baseDelay * ambientAnimationSpacingMultiplier / max(0.5, speakingFrequencyMultiplier), hold)
        idleBeatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireIdleBeat()
            }
        }
    }

    /// Drives *animation* variety only.
    ///
    /// Every bark this used to emit has been deleted, on request: the 18%
    /// `idleAmbient + mischief` branch, the 50%-of-flourish `caneFlourish`
    /// line, and the 50%-of-curious `curiosity` line. All three fired on a
    /// 4-9s timer with no reference to anything happening on the machine,
    /// which is exactly the "idle non-contextual comments" that needed to go.
    /// Bill still moves just as often — he simply no longer narrates it.
    /// The idle-beat rotation, restructured per the user's asks:
    /// - **Every animation family is reachable from rest**, not just the
    ///   old handful — tiered by rarity.
    /// - **Red-chaos families stay genuinely rare** — the "don't have too
    ///   much of the red shooting cloud" ask. Meltdown/rampaging/shadow
    ///   hands live in the seldom tier *and* remain in the Easter-egg roll,
    ///   never the common rotation.
    /// - **Beats hold for the whole clip** plus a breathing gap — the
    ///   "not playing long enough" fix: the next idle beat can no longer
    ///   cut a showing animation short.
    private static let idleCommonStates: [BillState] = [
        .talking, .thinking, .happy, .smug, .confused, .dazed,
        .poked, .surprised, .coding, .focused, .caneFlourish, .caneTwist,
        .celebrating, .grumpEyes,
    ]
    private static let idleUncommonStates: [BillState] = [
        .annoyed, .channeling, .gaming, .guilty, .dreading, .grooving,
        .dispatching, .ambushed, .stressed, .watched, .flinching, .huffy,
        .pushingCode, .browsingStore, .dancing, .sculpting, .kinship,
        .fractaling, .presenting, .trickster, .darkWorld, .hollowed,
        .cultLeader, .spooked, .scanning, .sneaking, .glitching, .charged,
        .transferring, .summoning, .hookCane, .conjuring, .tumbling, .dashTarget,
    ]
    /// The red-shooting-cloud class — deliberately a small tier of their
    /// own on top of the rare-egg roll.
    /// Meltdown and shadow hands only — rampaging (the red shooting
    /// cloud) is deliberately NOT in any random rotation: the explicit
    /// "don't have too much of it" ask. It stays reachable through
    /// per-trigger assignment in Settings and the daily showcase.
    private static let idleSeldomStates: [BillState] = [
        .meltdown, .shadowHands,
    ]
    private static let commonTierChance = 0.55
    private static let seldomTierChance = 0.05

    /// Set by `holdBeat(for:)` — extends the *next* idle beat's delay so
    /// the clip that just started is guaranteed to finish (plus a gap)
    /// before anything else fires.
    private var pendingBeatExtension: TimeInterval?

    private func fireIdleBeat() {
        guard isRunning else { return }
        defer { scheduleNextIdleBeat() }
        guard stateMachine.currentState == .idle else { return }

        if rollFanServiceBark() { return }
        if rollRareEvent() { return }

        let roll = Double.random(in: 0..<1)
        if roll < Self.commonTierChance {
            playIdle(Self.idleCommonStates)
        } else if roll < Self.commonTierChance + Self.seldomTierChance {
            playIdle(Self.idleSeldomStates)
        } else {
            playIdle(Self.idleUncommonStates)
        }
    }

    /// Requests one of `states` (never the one that just played) and holds
    /// the next idle beat for the clip's full duration plus a gap.
    private func playIdle(_ states: [BillState]) {
        let candidates = states.filter { $0 != lastIdleState }
        guard let state = candidates.randomElement() ?? states.randomElement() else { return }
        lastIdleState = state
        stateMachine.request(state, force: true)
        holdBeat(for: state)
    }

    private var lastIdleState: BillState?

    private func holdBeat(for state: BillState) {
        let clip = AnimationClipLibrary.clip(for: state)
        pendingBeatExtension = max(pendingBeatExtension ?? 0, clip.singlePassDuration + 0.8)
    }

    /// Pure-text fan-service beats — the Gravity Falls appeal layer:
    /// occasionally the idle beat is a *line*, not a move. Deal offers
    /// (the pinky-out handshake bit) and the rare Caesar-cipher message
    /// straight out of Journal 3's cryptograms, hint included.
    private static let fanServiceChance = 0.06
    private static let cipherChance = 0.30

    private func rollFanServiceBark() -> Bool {
        guard Double.random(in: 0..<1) < Self.fanServiceChance else { return false }
        let key = Double.random(in: 0..<1) < Self.cipherChance
            ? "cipher.message"
            : "deal.offer"
        guard let line = DialogueLibrary.shared.line(key) else { return false }
        bark(line, importance: .always)
        pendingBeatExtension = max(pendingBeatExtension ?? 0, 2.5)
        return true
    }

    // MARK: - Daily animation catch-up

    /// Paces a background showcase of whatever has not been on screen today,
    /// so the whole library is genuinely seen rather than merely reachable.
    ///
    /// Self-rescheduling and adaptive: the delay is the remaining time before
    /// 23:00 divided by the number of animations still owed, clamped to
    /// 90s...20min. A quiet day therefore spaces them out; a day where most
    /// have already come up through ordinary triggers barely fires at all.
    private func scheduleNextCatchUp() {
        catchUpTimer?.invalidate()
        guard isRunning, let delay = coverage.nextCatchUpDelay() else {
            // Nothing owed. Re-check in a while rather than stopping forever,
            // since midnight will refill the backlog.
            catchUpTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.scheduleNextCatchUp() }
            }
            return
        }
        catchUpTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireCatchUp() }
        }
    }

    private func fireCatchUp() {
        defer { scheduleNextCatchUp() }
        guard isRunning else { return }
        // Only ever from genuine rest — a showcase must never interrupt a
        // reaction, a chat exchange, or a roaming beat mid-flight.
        guard stateMachine.currentState == .idle else { return }
        guard let state = coverage.pick(from: coverage.unseenToday()) else { return }
        stateMachine.request(state, force: true)
        // The line describing a rare beat is contextual to the beat itself,
        // so it is kept — but it still respects the speaking-frequency slider.
        if let line = BarkLines.showcaseLine(for: state) {
            bark(line)
        }
    }

    /// Returns `true` if a rare Easter egg fired (caller should skip the
    /// normal idle-variant roll for this beat).
    private func rollRareEvent() -> Bool {
        if let last = lastRareEventDate, Date().timeIntervalSince(last) < Self.rareEventCooldown {
            return false
        }
        guard Double.random(in: 0..<1) < Self.rareEventChance else { return false }

        // `coverage.pick` rather than `randomElement`: it will not hand back
        // whatever played last, and it prefers eggs that have not been seen
        // today, so they cycle rather than clustering.
        guard let event = coverage.pick(from: BillState.rareEasterEggs) else { return false }
        lastRareEventDate = Date()
        stateMachine.request(event, force: true)
        holdBeat(for: event)
        bark(BarkLines.random(from: BarkLines.rareEvent(for: event)))
        return true
    }
}
