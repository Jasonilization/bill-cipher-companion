import Foundation

/// Maps normalized `SystemEvent`s to what Bill actually does: a state,
/// and/or a bark line. This is the only place system events and character
/// behavior meet — `SystemMonitor` stays dumb, `CharacterEngine`/
/// `BillStateMachine` stay unaware of *why* a state was requested.
@MainActor
final class ReactionRouter {
    private let characterEngine: CharacterEngine
    private var lastCategoryFire: [AppCategory: Date] = [:]
    private static let categoryCooldown: TimeInterval = 5 * 60

    init(characterEngine: CharacterEngine) {
        self.characterEngine = characterEngine
    }

    func handle(_ event: SystemEvent) {
        switch event {
        case .appActivated(_, let name, let category):
            handleAppActivated(name: name, category: category)

        case .batteryLow:
            // No dedicated "tired" state in the animation engine's 13 — reuse
            // `.annoyed` (closest existing emotional tone) and let the bark
            // line carry the battery-specific meaning. A proper "hunting for
            // a charger" walk is a nice polish-pass addition later.
            characterEngine.request(.annoyed)
            characterEngine.bark(BarkLines.random(from: BarkLines.batteryLow))

        case .batteryCharging:
            characterEngine.request(.charging)
            characterEngine.bark(BarkLines.random(from: BarkLines.batteryCharging))

        case .batteryUnplugged:
            characterEngine.request(.idle)

        case .networkLost:
            characterEngine.request(.surprised)
            characterEngine.bark(BarkLines.random(from: BarkLines.networkLost))

        case .networkRestored:
            characterEngine.bark(BarkLines.random(from: BarkLines.networkRestored))

        case .cpuHot:
            characterEngine.request(.heatingUp)
            characterEngine.bark(BarkLines.random(from: BarkLines.cpuHot))

        case .cpuNormal:
            characterEngine.request(.idle)

        case .userIdle:
            characterEngine.request(.sleeping)

        case .userReturned:
            characterEngine.request(.idle)
            characterEngine.bark(BarkLines.random(from: BarkLines.userReturned))
        }
    }

    private func handleAppActivated(name: String, category: AppCategory?) {
        guard let category else { return }

        if let last = lastCategoryFire[category], Date().timeIntervalSince(last) < Self.categoryCooldown {
            return
        }
        lastCategoryFire[category] = Date()

        switch category {
        case .coding:
            characterEngine.request(.coding)
            characterEngine.bark(BarkLines.random(from: BarkLines.coding))
        case .gaming:
            characterEngine.request(.gaming)
            characterEngine.bark(BarkLines.random(from: BarkLines.gaming))
        case .creative:
            // No dedicated creative pose/prop yet — coding's "watching
            // intently" pose is a reasonable stand-in until M5 gives
            // creative apps their own paintbrush prop.
            characterEngine.request(.coding)
            characterEngine.bark(BarkLines.random(from: BarkLines.creative))
        case .music:
            characterEngine.request(.happy)
            characterEngine.bark(BarkLines.random(from: BarkLines.music))
        case .browsing:
            // "Looks over curiously" doesn't need a dedicated state change —
            // just the comment.
            characterEngine.bark(BarkLines.random(from: BarkLines.browsing))
        }
    }
}
