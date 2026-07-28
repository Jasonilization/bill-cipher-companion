import Foundation

/// Maps a running app to one of Bill's reaction categories. Common apps are
/// hand-curated (there's no reliable generic signal for "this is a
/// browser", for instance); anything else falls back to the app's own
/// declared `LSApplicationCategoryType` (the same metadata the App Store
/// uses), so a random game or creative app the user has installed still
/// gets a sensible reaction without needing its bundle ID listed here.
enum AppCategoryMapper {
    private static let bundleIDOverrides: [String: AppCategory] = [
        // Coding
        "com.apple.dt.Xcode": .coding,
        "com.microsoft.VSCode": .coding,
        "com.microsoft.VSCodeInsiders": .coding,
        "com.apple.Terminal": .coding,
        "com.googlecode.iterm2": .coding,
        "com.jetbrains.intellij": .coding,
        "com.jetbrains.pycharm": .coding,
        "com.jetbrains.CLion": .coding,
        "com.sublimetext.4": .coding,
        "dev.warp.Warp-Stable": .coding,
        "com.vscodium": .coding,

        // Gaming (platforms/launchers — individual games are usually
        // covered by the LSApplicationCategoryType fallback below)
        "com.valvesoftware.steam": .gaming,
        "net.battle.app": .gaming,
        "com.epicgames.EpicGamesLauncher": .gaming,
        "com.gog.galaxy": .gaming,
        "com.blizzard.worldofwarcraft": .gaming,

        // Browsing — no generic App Store category exists for "browser"
        "com.apple.Safari": .browsing,
        "com.google.Chrome": .browsing,
        "com.google.Chrome.canary": .browsing,
        "com.microsoft.edgemac": .browsing,
        "org.mozilla.firefox": .browsing,
        "com.brave.Browser": .browsing,
        "company.thebrowser.Browser": .browsing,
        "com.operasoftware.Opera": .browsing,

        // Music
        "com.apple.Music": .music,
        "com.spotify.client": .music,

        // Creative
        "com.adobe.Photoshop": .creative,
        "com.figma.Desktop": .creative,
        "com.bohemiancoding.sketch3": .creative,
        "com.seriflabs.affinitydesigner2": .creative,
        "com.seriflabs.affinityphoto2": .creative,
        "com.pixelmatorteam.pixelmator.x": .creative,
        "com.pixelmatorteam.pixelmator": .creative,
    ]

    private static let categoryUTIMap: [String: AppCategory] = [
        "public.app-category.games": .gaming,
        "public.app-category.developer-tools": .coding,
        "public.app-category.music": .music,
        "public.app-category.graphics-design": .creative,
        "public.app-category.photography": .creative,
        "public.app-category.video": .creative,
    ]

    static func category(bundleID: String, bundleURL: URL?) -> AppCategory? {
        if let known = bundleIDOverrides[bundleID] {
            return known
        }
        guard let bundleURL, let bundle = Bundle(url: bundleURL),
              let uti = bundle.infoDictionary?["LSApplicationCategoryType"] as? String
        else {
            return nil
        }
        return categoryUTIMap[uti]
    }
}
