import SpriteKit
import Foundation

/// A second character living in the primary character's window — Sans
/// brings Papyrus, the Knight brings Hornet. Multi-character support
/// without a second window, second render loop, or second roaming sim:
/// the companion is a full rig + state machine (so it benefits from the
/// exact same clip/texture system), but it stays parked at its side of
/// the window while the primary character roams and reacts.
///
/// Its behavior is deliberately simpler than the primary's:
/// - Ambient beats: occasionally plays one of its own families.
/// - Reactions: fires on a *fraction* of the primary's app reactions, so
///   it feels like it's paying attention without doubling the chatter.
/// - Banter: sometimes *responds* to what the primary just said, drawn
///   from its own dialogue pools ("banter.respond"), which is what makes
///   a pair read as a pair rather than two pets in a trench coat.
@MainActor
final class CompanionController {
    let definition: CharacterDefinition
    let rig: BillRigNode
    let stateMachine: BillStateMachine
    private let catalog: CharacterSpriteCatalog
    private let library: CharacterAnimationLibrary
    /// This companion's OWN voice — never the primary's. The shared
    /// `DialogueLibrary` only ever holds the primary character's pools,
    /// so a companion speaking through it would talk in the primary's
    /// voice (Papyrus saying Sans's lines).
    private let voice: DialogueVoice
    /// Where companion bark text goes — routed through the primary's bark
    /// queue so the shared bark panel serializes both voices (the panel
    /// is positioned over the shared window).
    private let barkSink: (String) -> Void

    private var beatTimer: Timer?
    private weak var scene: SKScene?
    private var lastBeat: BillState?
    private var lastPrimaryBarkAt: Date?
    private var respondedToBarkAt: Date?

    /// The states a companion cycles through when it fancies a move — all
    /// safe anywhere, at any time. No roaming beats, no rare eggs: the
    /// companion's drama budget is small on purpose; the window is a stage,
    /// not a battlefield.
    private static let beatStates: [BillState] = [
        .idle, .talking, .happy, .annoyed, .surprised, .smug, .confused, .dazed,
    ]

    /// The companion's rest-frame bottom gap, in unscaled points —
    /// uniform-canvas sheets (HK named frames) need it subtracted from
    /// their anchor so visual feet reach the floor (see
    /// CharacterSpriteCatalog.restGap).
    var restGapPoints: CGFloat {
        CGFloat(catalog.restGap) * definition.displayScale
    }

    init(definition: CharacterDefinition, barkSink: @escaping (String) -> Void) {
        self.definition = definition
        self.barkSink = barkSink
        voice = DialogueVoice(character: definition)
        let packCatalog = CharacterSpriteCatalog(definition: definition)
        catalog = packCatalog
        library = CharacterAnimationLibrary(catalog: packCatalog)
        rig = BillRigNode.build(catalog: packCatalog, displayScale: definition.displayScale)
        let library = self.library
        stateMachine = BillStateMachine(
            rig: rig,
            clipProvider: { library.clip(for: $0) },
            restTexture: packCatalog.restTexture,
            idleVariants: { library.idleVariant($0) }
        )
        stateMachine.overlayProvider = { library.overlayClip(for: $0) }
        stateMachine.allowsBillFX = false
        rig.root.name = "companionRoot"
    }

    // MARK: - Scene lifecycle

    func attach(to scene: SKScene?) {
        guard let scene else { return }
        self.scene = scene
        rig.root.removeFromParent()
        scene.addChild(rig.root)
        stateMachine.request(.idle)
        startBeats()
        startWandering()
    }

    func detach() {
        stopBeats()
        stopWandering()
        stateMachine.clearBarkQueue()
        rig.root.removeFromParent()
    }

    // MARK: - Wandering

    private var wanderTimer: Timer?
    private var isWandering = false
    /// Companions are not statuary: every so often one strolls across its
    /// share of the window — its own walk family, its own direction — then
    /// settles back to idle. Only ever starts from genuine rest, so it can
    /// never interrupt a reaction beat or banter, and it keeps clear of
    /// the primary's spot so the window never becomes a shuffle pile.
    private func startWandering() {
        scheduleWander()
    }

    private func stopWandering() {
        wanderTimer?.invalidate()
        wanderTimer = nil
        rig.root.removeAction(forKey: "wanderMove")
        isWandering = false
    }

    private func scheduleWander() {
        wanderTimer?.invalidate()
        let delay = Double.random(in: 8...22)
        wanderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.wanderStep() }
        }
    }

    private func wanderStep() {
        defer { scheduleWander() }
        guard !isWandering, stateMachine.currentState == .idle else { return }
        guard let scene = rig.root.scene else { return }
        let width = scene.frame.width
        guard width > 220 else { return }

        // Prefer a spot away from the primary (and from this companion's
        // current position — a stroll of a few points reads as a twitch).
        let primaryX = scene.children
            .first { $0.name == "characterRoot" }?.position.x
        var candidates = (0..<4).map { _ in
            CGFloat.random(in: width * 0.12...width * 0.88)
        }
        if let px = primaryX {
            candidates.sort { abs($0 - px) > abs($1 - px) }
        }
        guard let target = candidates.first else { return }
        let dx = target - rig.root.position.x
        guard abs(dx) > 50 else { return }

        isWandering = true
        // Directional walk rows are the sheet's own art — set the
        // library's direction; the body is never mirrored (pack rule).
        library.walkDirection = dx > 0 ? 1 : -1
        stateMachine.request(.walking, force: true)

        // Walk at the same visual pace as the primary's top-down strolls.
        let duration = TimeInterval(abs(dx) / 60.0)
        let move = SKAction.moveTo(x: target, duration: duration)
        let settle = SKAction.run { [weak self] in
            guard let self else { return }
            self.isWandering = false
            if self.stateMachine.currentState == .walking {
                self.stateMachine.request(.idle)
            }
        }
        rig.root.run(SKAction.sequence([move, settle]), withKey: "wanderMove")
    }

    // MARK: - Ambient beats

    private func startBeats() {
        beatTimer?.invalidate()
        scheduleNextBeat()
    }

    private func stopBeats() {
        beatTimer?.invalidate()
        beatTimer = nil
    }

    private func scheduleNextBeat() {
        // 14–40s: present enough to be company, sparse enough that it never
        // competes with the primary's reactions.
        let delay = Double.random(in: 14...40)
        beatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireBeat() }
        }
    }

    private func fireBeat() {
        defer { scheduleNextBeat() }
        guard stateMachine.currentState == .idle else { return }
        // Collision banter: when this companion's rig overlaps another rig
        // in the same window, they both react — a surprised beat plus a
        // character-voiced "ouch" exchange. Cooldown keeps a tangled
        // window from becoming a shouting match.
        if checkCollisions() { return }
        let candidates = Self.beatStates.filter { $0 != lastBeat }
        guard let state = candidates.randomElement() else { return }
        lastBeat = state
        stateMachine.request(state, force: true)

        // A move is sometimes worth a word — its own voice, from its own
        // pools, through the shared bark panel.
        if Double.random(in: 0..<1) < 0.35,
           !AppPreferences.isMutedCompanionShared(definition.id),
           let key = DialogueKey(rawValue: state.rawValue),
           let line = voice.line(key) {
            barkSink(line)
        }
    }

    // MARK: - Collisions

    private var lastOuchAt: Date?
    private static let ouchCooldown: TimeInterval = 20

    /// Rigs near enough to "bump". Returns true when a collision fired so
    /// the caller skips the normal beat.
    private func checkCollisions() -> Bool {
        guard let last = lastOuchAt,
              Date().timeIntervalSince(last) > Self.ouchCooldown else {
            lastOuchAt = lastOuchAt ?? Date()
            return false
        }
        guard let scene = rig.root.scene else { return false }
        let myFrame = rig.root.calculateAccumulatedFrame()
        var bumped: SKNode?
        for child in scene.children
        where child !== rig.root && (child.name == "characterRoot" || child.name == "companionRoot") {
            if myFrame.insetBy(dx: -8, dy: -4).intersects(child.calculateAccumulatedFrame()) {
                bumped = child
                break
            }
        }
        guard bumped != nil else { return false }
        lastOuchAt = Date()
        stateMachine.request(.surprised, force: true)
        if !AppPreferences.isMutedCompanionShared(definition.id),
           let line = voice.line("collision.ouch") ?? voice.line("poked") {
            barkSink(line)
        }
        return true
    }

    // MARK: - Banter

    /// Called by the window controller whenever the *primary* character
    /// barks. Most of the time the companion stays quiet (sidekicks know
    /// when not to steal a line); occasionally it quips back, which is
    /// the whole reason to ship characters in pairs.
    func primaryBarked() {
        lastPrimaryBarkAt = Date()
        // Never twice in a row, never within 8s of its own last response,
        // and only ~22% of the time.
        guard let last = respondedToBarkAt,
              Date().timeIntervalSince(last) > 8 else {
            respondedToBarkAt = respondedToBarkAt ?? Date()
            return
        }
        guard Double.random(in: 0..<1) < 0.22 else { return }
        // Pair-specific banter first ("what's that cat doing there?" /
        // "I'm not a cat!!") — the cross-pack exchange tables.
        let pairKey = "pair.\(AppPreferences.activeCharacterShared)-\(definition.id)"
        guard !AppPreferences.isMutedCompanionShared(definition.id) else { return }
        guard let line = voice.line(pairKey) ?? voice.line("banter.respond") else { return }
        respondedToBarkAt = Date()
        // Face its partner: a small reaction beat, then the quip.
        stateMachine.request(.talking, force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.barkSink(line)
        }
    }
}
