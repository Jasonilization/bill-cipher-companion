import SpriteKit

/// Bill's colour palette. This is an original stylised interpretation of his
/// silhouette (triangle, single eye, bow tie, top hat, cane) drawn procedurally
/// in code — no imported artwork.
enum BillPalette {
    static let bodyYellow = SKColor(red: 0.98, green: 0.78, blue: 0.15, alpha: 1)
    static let bodyYellowDark = SKColor(red: 0.72, green: 0.52, blue: 0.04, alpha: 1)
    static let eyeWhite = SKColor(white: 0.98, alpha: 1)
    static let pupilBlack = SKColor(red: 0.08, green: 0.05, blue: 0.02, alpha: 1)
    static let black = SKColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    static let gloveWhite = SKColor(white: 0.95, alpha: 1)
    static let blush = SKColor(red: 1.0, green: 0.4, blue: 0.35, alpha: 0.55)

    // MARK: - User-tunable bubble accent (Settings → Appearance)

    /// The accent ring colour of every speech bubble (bark, chat messages,
    /// composer) — Bill's canon yellow unless the user recolours it. Set
    /// live by `AppDelegate` from `AppPreferences.bubbleAccentColorHex`;
    /// mutating triggers a bubble redraw on the next draw pass.
    /// `bodyYellow` stays constant: *Bill himself* is not recolourable
    /// from Settings, only his bubbles.
    @MainActor static var bubbleAccent: SKColor = bodyYellow

    /// Parses a 6-digit hex string (no `#`) into a colour, falling back to
    /// canon yellow on anything malformed — a typo in defaults storage
    /// must never turn the bubbles invisible.
    @MainActor static func color(fromHex hex: String) -> SKColor {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        var value: UInt64 = 0
        guard clean.count == 6, Scanner(string: clean).scanHexInt64(&value) else { return bodyYellow }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return SKColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Hex string for the current `bubbleAccent` (round-trips the picker).
    @MainActor static var bubbleAccentHex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        bubbleAccent.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }
}
