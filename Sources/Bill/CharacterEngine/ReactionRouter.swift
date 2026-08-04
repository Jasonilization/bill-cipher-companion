import Foundation

/// Maps normalized `SystemEvent`s to what Bill actually does: a state,
/// and/or a bark line. This is the only place system events and character
/// behavior meet — `SystemMonitor` stays dumb, `CharacterEngine`/
/// `BillStateMachine` stay unaware of *why* a state was requested.
///
/// Also the only place that reads `MemoryStore` for *contextual* dialogue
/// decisions (returning to an app repeatedly, referencing it by name) —
/// `MemoryStore` itself stays a dumb log/counter, same separation of
/// concerns as everything else here.
@MainActor
final class ReactionRouter {
    private let characterEngine: CharacterEngine
    private let preferences: AppPreferences
    private let memoryStore: MemoryStore
    private var lastCategoryFire: [AppCategory: Date] = [:]
    private var lastGenericAppFire: Date?
    private var lastFavoriteFire: Date?
    private var idleStartDate: Date?
    private static let categoryCooldown: TimeInterval = 5 * 60
    private static let genericAppCooldown: TimeInterval = 8 * 60
    private static let favoriteCooldown: TimeInterval = 20 * 60
    /// How many times (within the last hour) counts as "you keep coming
    /// back to this" rather than just a normal reopen.
    private static let favoriteRecentThreshold = 3
    private static let favoriteRecentWindow: TimeInterval = 60 * 60

    init(characterEngine: CharacterEngine, preferences: AppPreferences, memoryStore: MemoryStore) {
        self.characterEngine = characterEngine
        self.preferences = preferences
        self.memoryStore = memoryStore
    }

    func handle(_ event: SystemEvent) {
        switch event {
        case .appActivated(let bundleID, let name, let category):
            // Recorded *before* the recency/frequency checks below read it,
            // so "you keep coming back to this" can see this activation too.
            memoryStore.recordAppOpen(bundleID: bundleID, name: name, category: category)
            handleAppActivated(bundleID: bundleID, name: name, category: category)

        case .batteryLow:
            // No dedicated "tired" state in the animation engine's states —
            // reuse `.annoyed` (closest existing emotional tone) and let the
            // bark line carry the battery-specific meaning.
            memoryStore.recordLowBatteryEvent()
            characterEngine.request(.annoyed)
            characterEngine.bark(BarkLines.random(from: BarkLines.batteryLow))

        case .batteryCharging:
            memoryStore.recordChargingEvent()
            characterEngine.request(.charging)
            characterEngine.bark(BarkLines.random(from: BarkLines.batteryCharging))

        case .batteryUnplugged:
            characterEngine.request(.idle)

        case .networkLost:
            // Spec: "notices, acts confused, complains" — confused is a
            // closer match than reusing surprised now that a dedicated
            // confused animation exists.
            characterEngine.request(.confused)
            characterEngine.bark(BarkLines.random(from: BarkLines.networkLost))

        case .networkRestored:
            characterEngine.bark(BarkLines.random(from: BarkLines.networkRestored))

        case .cpuHot:
            characterEngine.request(.heatingUp)
            characterEngine.bark(BarkLines.random(from: BarkLines.cpuHot))

        case .cpuNormal:
            characterEngine.request(.idle)

        case .userIdle:
            idleStartDate = Date()
            characterEngine.bark(BarkLines.random(from: BarkLines.gettingSleepy))
            characterEngine.request(.sleeping)

        case .userReturned:
            if let idleStartDate {
                memoryStore.recordIdleDuration(Date().timeIntervalSince(idleStartDate))
            }
            idleStartDate = nil
            // Distinguish "Bill was actually asleep" from an ordinary
            // away-and-back — a wake-up line reads oddly if Bill was just
            // idly standing there the whole time.
            let wasAsleep = characterEngine.stateMachine.currentState == .sleeping
            characterEngine.request(.idle)
            characterEngine.bark(BarkLines.random(from: wasAsleep ? BarkLines.waking : BarkLines.userReturned))
        }
    }

    private func handleAppActivated(bundleID: String, name: String, category: AppCategory?) {
        guard let category else {
            handleUncategorizedApp(bundleID: bundleID, name: name)
            return
        }
        guard preferences.isCategoryEnabled(category) else { return }

        if isReturningFavorite(bundleID: bundleID) {
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.returningFavorite, appName: name))
            // `.celebrating` had no caller anywhere in the app despite being
            // a fully-built state — "you keep coming back to this" is
            // exactly the small positive moment it's for. It settles back
            // to idle on its own (one-shot), so the category request right
            // below still lands right after rather than being blocked.
            characterEngine.request(.celebrating, force: true)
        }

        if let last = lastCategoryFire[category], Date().timeIntervalSince(last) < Self.categoryCooldown {
            return
        }
        lastCategoryFire[category] = Date()

        switch category {
        case .coding:
            characterEngine.request(.coding)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.coding, appName: name))
        case .gaming:
            characterEngine.request(.gaming)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.gaming, appName: name))
        case .creative:
            // No dedicated creative pose yet — coding's "watching intently"
            // pose (a real sprite state, not a placeholder) is a reasonable
            // stand-in until the sheet yields a dedicated creative frame.
            characterEngine.request(.coding)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.creative, appName: name))
        case .music:
            characterEngine.request(.happy)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.music, appName: name))
        case .browsing:
            // "Looks over curiously" doesn't need a dedicated state change —
            // just the comment.
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.browsing, appName: name))
        case .finder:
            characterEngine.bark(BarkLines.random(from: BarkLines.finder))
        case .communication:
            // Addressing someone else — `.talking`'s hand-raised gesture
            // fits directly, unlike `.coding`'s "watching intently" read.
            characterEngine.request(.talking)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.communication, appName: name))
        case .productivity:
            characterEngine.request(.focused)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.productivity, appName: name))
        case .aiChat:
            // Knowing/territorial rather than neutral — see `BarkLines.
            // aiChat`'s doc comment.
            characterEngine.request(.smug)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.aiChat, appName: name))
        case .tinkering:
            characterEngine.request(.channeling)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.tinkering, appName: name))
        }
    }

    /// "You keep coming back to this, don't you?" — fired (on its own
    /// cooldown, separate from the category cooldown) when an app has been
    /// reopened often enough recently to read as a genuine pattern rather
    /// than incidental app-switching.
    private func isReturningFavorite(bundleID: String) -> Bool {
        if let last = lastFavoriteFire, Date().timeIntervalSince(last) < Self.favoriteCooldown {
            return false
        }
        guard memoryStore.recentOpenCount(for: bundleID, within: Self.favoriteRecentWindow) >= Self.favoriteRecentThreshold else {
            return false
        }
        lastFavoriteFire = Date()
        return true
    }

    /// How many opens of an uncategorized app reads as "you keep coming
    /// back to this" rather than a one-off — independent of
    /// `favoriteRecentThreshold`/`favoriteRecentWindow` above, which is
    /// specifically about *categorized* apps' recency-windowed "returning
    /// favorite" beat; this is a plain lifetime count, since an app Bill
    /// still can't name a category for doesn't get that whole mechanism.
    private static let uncategorizedFrequentThreshold = 3

    /// Apps with no recognized category still get an occasional reaction —
    /// otherwise every unlisted app launch is silent, which reads as Bill
    /// not noticing anything outside a handful of hand-picked apps. Learns
    /// gradually via `MemoryStore` (see its "App-learning additions" and
    /// `CharacterWindowController`'s daily refresh, which is what actually
    /// populates `appDescriptions`): a brand new app gets a curious glance,
    /// one Bill has a learned description for gets a knowing dismissal
    /// instead of the plain generic line, and one that's been reopened a
    /// lot but is *still* undescribed gets a smug "still no idea" beat.
    /// Same longer cooldown as before either way, since this still covers
    /// a much wider, noisier slice of app launches than named categories.
    private func handleUncategorizedApp(bundleID: String, name: String) {
        if let last = lastGenericAppFire, Date().timeIntervalSince(last) < Self.genericAppCooldown {
            return
        }
        lastGenericAppFire = Date()

        if let description = memoryStore.description(for: bundleID) {
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.appLaunchDescribed, appName: name, description: description))
            if memoryStore.openCount(for: bundleID) >= Self.uncategorizedFrequentThreshold {
                characterEngine.request(.smug, force: true)
            }
            return
        }

        if memoryStore.isFirstSighting(of: bundleID) {
            characterEngine.stateMachine.playIdleVariant(.curious)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.appLaunchFirstSighting, appName: name))
            return
        }

        if memoryStore.openCount(for: bundleID) >= Self.uncategorizedFrequentThreshold {
            characterEngine.request(.smug, force: true)
            characterEngine.bark(BarkLines.resolvedRandom(from: BarkLines.appLaunchStillUnknown, appName: name))
            return
        }

        characterEngine.bark(BarkLines.random(from: BarkLines.appLaunchGeneric))
    }
}
