import Foundation
import Combine
import ServiceManagement
import SwiftUI

/// User-facing toggles, persisted to `UserDefaults` — no API key field here,
/// there's nothing to manage since chat goes through the user's own logged-
/// in ChatGPT session.
@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let roaming = "billRoamingEnabled"
        static let disabledCategories = "billDisabledCategories"
        static let adLib = "billAdLibEnabled"
    }

    @Published var isRoamingEnabled: Bool {
        didSet { UserDefaults.standard.set(isRoamingEnabled, forKey: Keys.roaming) }
    }

    @Published var disabledCategories: Set<AppCategory> {
        didSet {
            UserDefaults.standard.set(disabledCategories.map(\.rawValue), forKey: Keys.disabledCategories)
        }
    }

    /// Off by default: routing ambient commentary through the chat bridge
    /// has real latency/cost, unlike the free, instant local bark lines.
    @Published var isAdLibEnabled: Bool {
        didSet { UserDefaults.standard.set(isAdLibEnabled, forKey: Keys.adLib) }
    }

    @Published private(set) var launchAtLoginStatus: SMAppService.Status

    init() {
        let defaults = UserDefaults.standard
        isRoamingEnabled = (defaults.object(forKey: Keys.roaming) as? Bool) ?? true
        isAdLibEnabled = (defaults.object(forKey: Keys.adLib) as? Bool) ?? false
        let disabledRaw = defaults.stringArray(forKey: Keys.disabledCategories) ?? []
        disabledCategories = Set(disabledRaw.compactMap(AppCategory.init(rawValue:)))
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func isCategoryEnabled(_ category: AppCategory) -> Bool {
        !disabledCategories.contains(category)
    }

    func setCategory(_ category: AppCategory, enabled: Bool) {
        if enabled {
            disabledCategories.remove(category)
        } else {
            disabledCategories.insert(category)
        }
    }

    func binding(for category: AppCategory) -> Binding<Bool> {
        Binding(
            get: { self.isCategoryEnabled(category) },
            set: { self.setCategory(category, enabled: $0) }
        )
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("AppPreferences: failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }
}
