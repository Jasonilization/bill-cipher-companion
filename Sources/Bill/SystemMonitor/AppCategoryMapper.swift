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
        "com.electron.dockerdesktop": .coding,

        // Gaming (platforms/launchers — most individual games are covered by
        // the LSApplicationCategoryType fallback below, but Steam games in
        // particular often ship with no `LSApplicationCategoryType` set at
        // all, so the ones actually in this dock are listed explicitly).
        "com.valvesoftware.steam": .gaming,
        "net.battle.app": .gaming,
        "com.epicgames.EpicGamesLauncher": .gaming,
        "com.gog.galaxy": .gaming,
        "com.blizzard.worldofwarcraft": .gaming,
        "com.Massive-Monster.Cult-Of-The-Lamb": .gaming,
        "com.tobyfox.undertale": .gaming,
        "com.tobyfox.deltarune": .gaming,
        "unity.Team Cherry.Hollow Knight": .gaming,

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
        "org.blenderfoundation.blender": .creative,
        "com.orama-interactive.pixelorama": .creative,
        "com.jasonilization.mandelbrotexplorer": .creative,

        // Finder — a system app with no LSApplicationCategoryType of its own.
        "com.apple.finder": .finder,

        // Communication
        "com.apple.mail": .communication,
        "us.zoom.xos": .communication,
        "com.tencent.xinWeChat": .communication,
        "com.apple.MobileSMS": .communication,

        // Productivity
        "com.apple.Notes": .productivity,

        // AI chat — deliberately its own category, not `.coding`/`.creative`,
        // since the reaction (see `ReactionRouter`) is a knowing dig at
        // "another AI" rather than a neutral work pose.
        "com.openai.codex": .aiChat,
        "com.openai.chat": .aiChat,

        // Tinkering — hacking/hardware/mad-science tools. This is where
        // Bill's mystical-schemer personality gets to have the most fun.
        "org.wireshark.Wireshark": .tinkering,
        "oorg.sdrpp.sdrpp": .tinkering,
        "com.altillimity.satdump": .tinkering,
        "com.raspberrypi.rpi-imager": .tinkering,
        "io.balena.etcher": .tinkering,
        "com.yourcompany.qFlipper": .tinkering,
        "com.utmapp.UTM": .tinkering,
    ]

    private static let categoryUTIMap: [String: AppCategory] = [
        "public.app-category.games": .gaming,
        "public.app-category.developer-tools": .coding,
        "public.app-category.music": .music,
        "public.app-category.graphics-design": .creative,
        "public.app-category.photography": .creative,
        "public.app-category.video": .creative,
        "public.app-category.education": .productivity,
        "public.app-category.productivity": .productivity,
        "public.app-category.social-networking": .communication,
    ]

    /// Safari Web Apps (sites pinned to the Dock via "Add to Dock") each get
    /// a random per-installation bundle ID like
    /// `com.apple.Safari.WebApp.<UUID>` — there's no stable identifier to
    /// hardcode for these the way there is for a real native app, so they're
    /// matched by their (stable, user-visible) Dock label instead. Matching
    /// is case-insensitive substring, not exact, so small name variations
    /// (a site's tab title changing slightly, "Google Docs" vs "Docs") don't
    /// silently stop matching.
    private static let webAppNameOverrides: [(match: String, category: AppCategory)] = [
        ("google docs", .productivity),
        ("google sheets", .productivity),
        ("google slides", .productivity),
        ("google classroom", .productivity),
        ("drive", .productivity),
        ("duolingo", .productivity),
        ("shrewsbury", .productivity),
        ("socs", .productivity),
        ("student", .productivity),
        ("gmail", .communication),
        ("chat", .communication),
        ("youtube", .music),
        ("github", .coding),
        ("canva", .creative),
    ]

    static func category(bundleID: String, bundleURL: URL?, name: String = "") -> AppCategory? {
        if let known = bundleIDOverrides[bundleID] {
            return known
        }
        if bundleID.hasPrefix("com.apple.Safari.WebApp"), !name.isEmpty {
            let lowered = name.lowercased()
            if let match = webAppNameOverrides.first(where: { lowered.contains($0.match) }) {
                return match.category
            }
        }
        guard let bundleURL, let bundle = Bundle(url: bundleURL),
              let uti = bundle.infoDictionary?["LSApplicationCategoryType"] as? String
        else {
            return nil
        }
        return categoryUTIMap[uti]
    }
}
