import Foundation

/// Per-app overrides that bypass `AppCategoryMapper`'s broad buckets entirely —
/// checked first in `ReactionRouter.handleAppActivated`. Where `AppCategoryMapper`
/// groups "anything that's a game" into one `.gaming` reaction, this is for the
/// apps distinctive enough (individual Steam games, specific hobby tools) to
/// deserve their own animation from the sheet rather than sharing a generic one.
enum SpecialAppMapper {
    /// Exact bundle ID match — used for native apps, where the identifier is
    /// stable across installs.
    private static let bundleIDOverrides: [String: BillState] = [
        "com.tobyfox.undertale": .trickster,  // UNDERTALE
        "com.tobyfox.deltarune": .darkWorld,  // DELTARUNE
        "unity.Team Cherry.Hollow Knight": .hollowed,  // Hollow Knight
        "com.Massive-Monster.Cult-Of-The-Lamb": .cultLeader,  // Cult Of The Lamb
        "oorg.sdrpp.sdrpp": .scanning,  // SDR++
        "com.altillimity.satdump": .scanning,  // SatDump
        "org.wireshark.Wireshark": .sneaking,  // Wireshark
        "com.utmapp.UTM": .glitching,  // UTM
        "com.yourcompany.qFlipper": .charged,  // qFlipper
        "com.raspberrypi.rpi-imager": .transferring,  // Raspberry Pi Imager
        "io.balena.etcher": .transferring,  // balenaEtcher
        "com.electron.dockerdesktop": .summoning,  // Docker Desktop
        "org.blenderfoundation.blender": .sculpting,  // Blender
        "com.orama-interactive.pixelorama": .kinship,  // Pixelorama
        "com.jasonilization.mandelbrotexplorer": .fractaling,  // Mandelbrot Explorer
        "com.apple.mail": .dispatching,  // Mail
        "com.apple.AppStore": .ambushed,  // App Store
        "com.apple.ActivityMonitor": .stressed,  // Activity Monitor
        "com.apple.systempreferences": .watched,  // System Settings
        "com.apple.PhotoBooth": .flinching,  // Photo Booth
        "net.freemacsoft.AppCleaner": .huffy,  // AppCleaner
        "com.valvesoftware.steam": .browsingStore,  // Steam
        "com.spotify.client": .dancing,  // Spotify
    ]

    /// Case-insensitive substring match against the app's *display name* —
    /// used for Safari Web Apps, whose bundle ID is a random per-install UUID
    /// (see `AppCategoryMapper.webAppNameOverrides` for the same pattern).
    private static let nameOverrides: [(match: String, state: BillState)] = [
        ("baldi", .spooked),  // Baldi's Basics (bundle id unreadable, name match)
        ("canva", .presenting),  // Canva (webapp)
        ("duolingo", .guilty),  // Duolingo (webapp)
        ("shrewsbury", .dreading),  // school portal (webapp)
        ("socs", .dreading),  // school portal (webapp)
        ("student", .dreading),  // school portal (webapp)
        ("classroom", .dreading),  // Google Classroom (webapp)
        ("youtube", .grooving),  // YouTube (webapp)
        ("github", .pushingCode),  // GitHub (webapp)
    ]

    static func state(bundleID: String, name: String) -> BillState? {
        if let known = bundleIDOverrides[bundleID] {
            return known
        }
        let lowered = name.lowercased()
        return nameOverrides.first(where: { lowered.contains($0.match) })?.state
    }
}
