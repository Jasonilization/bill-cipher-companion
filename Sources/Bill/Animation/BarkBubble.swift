import AppKit
import SpriteKit

/// Builds Bill's speech bubble as a genuinely pixel-art bitmap.
///
/// The previous version drew text with a real `NSFont` (Monaco) at a tiny
/// point size with antialiasing disabled. That's what produced the "thin,
/// vertically-stretched" look the user flagged: system font hinting isn't
/// designed for zero-antialiasing rendering at 8pt, so strokes render
/// unevenly (some vanish, making the glyph read as thin; the fixed cap
/// height next to those thin strokes reads as stretched). Turning
/// antialiasing back on would fix the unevenness but produce smooth/blurry
/// text, which is the opposite of "pixel art."
///
/// The fix is to stop asking a scalable font to behave like a bitmap font:
/// `PixelFont` below is a hand-built 5x7 dot-matrix glyph table, rendered as
/// filled unit squares with no font rendering involved at all. Every glyph
/// has identical, guaranteed-consistent stroke weight and aspect ratio at
/// any scale — there's nothing for the renderer to get wrong.
///
/// The border is a true pixel-rounded rect (a quarter-circle raster mask
/// per corner — see `fillPixelRoundedRect`), not a single small diagonal
/// chamfer — the previous 3-unit chamfer was proportionally too small to
/// read as "rounded" at this bubble's size and just looked like a sharp
/// rectangle.
@MainActor
enum BarkBubble {
    /// Final on-screen multiplier for the whole bitmap. Every dimension
    /// below is in "bubble units" (1 unit = 1 source pixel before this
    /// multiplier) so the border, tail, and font all share one consistent
    /// grid and scale together with no risk of one axis stretching
    /// relative to another.
    private static let pixelScale: CGFloat = 3

    // MARK: - Layout grid (all in bubble units)

    private static let paddingX: CGFloat = 7
    private static let paddingY: CGFloat = 6
    private static let cornerRadius = 3
    private static let borderThickness = 1
    private static let accentThickness = 1
    private static let tailHeight: CGFloat = 5
    /// Keeps the widest possible bubble inside the 260pt-wide character
    /// window (the bubble is a child node of Bill's own scene, not a
    /// separate window, so anything wider gets clipped by the view bounds
    /// — the exact "resizing looks wrong" bug for long lines).
    private static let maxTextWidthUnits = 66
    /// The narrowest text column the bubble will ever wrap into — below
    /// this the words get too cramped to read, so a window that's almost
    /// entirely off-screen (the only case that could demand less room)
    /// truncates instead of wrapping into a sliver.
    private static let minTextWidthUnits = 20
    /// Caps vertical growth for the same reason — the character window's
    /// height (`CharacterWindowController`) is sized to leave enough
    /// headroom above Bill's head for this many lines without the bubble
    /// itself getting clipped by the window's own top edge. Raised well
    /// past the old cap of 6 (which was truncating with "…" for anything
    /// longer than a short one-liner, including the ChatGPT-generated
    /// dialogue lines and any longer static bark) — idle/ambient text
    /// should always show in full.
    private static let maxLines = 14

    static func makeNode(text: String, maxWidth: CGFloat) -> SKNode {
        // Honor the caller's measured on-screen room: the caller
        // (`BillStateMachine.present`) passes the width of the window's
        // on-screen region so a bubble placed while Bill stands at a
        // screen edge wraps to what's actually visible instead of the
        // full 66-unit column. The parameter used to be accepted and
        // silently ignored, which is how a wide bubble could be placed
        // and then nudged into a region it never fit.
        let chromeUnits = paddingX * 2 + CGFloat(borderThickness + accentThickness) * 2
        let roomUnits = Int((maxWidth / pixelScale).rounded(.down)) - Int(chromeUnits)
        let textColumnUnits = min(maxTextWidthUnits, max(minTextWidthUnits, roomUnits))
        let lines = PixelFont.wrap(normalize(text.uppercased()), maxWidthUnits: textColumnUnits, maxLines: maxLines)

        let textBlockWidth = CGFloat(lines.map(PixelFont.lineWidth).max() ?? 0)
        let textBlockHeight = CGFloat(lines.count) * PixelFont.lineHeight - PixelFont.lineSpacing

        let bodyWidth = textBlockWidth + paddingX * 2
        let bodyHeight = textBlockHeight + paddingY * 2
        let imageSize = CGSize(width: bodyWidth, height: bodyHeight + tailHeight)

        let image = NSImage(size: imageSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(false)
            ctx.setAllowsAntialiasing(false)
            ctx.interpolationQuality = .none

            let bodyRect = CGRect(x: 0, y: tailHeight, width: bodyWidth, height: bodyHeight)
            let fillRect = drawLayeredBorder(ctx, bodyRect: bodyRect, cornerRadius: cornerRadius, borderThickness: borderThickness, accentThickness: accentThickness, accentColor: BillPalette.bodyYellow)
            drawTail(ctx, bodyRect: bodyRect)
            PixelFont.drawCentered(ctx, lines: lines, in: fillRect, color: BillPalette.black)

            return true
        }

        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest
        let sprite = SKSpriteNode(texture: texture)
        sprite.setScale(pixelScale)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        return sprite
    }

    /// ChatGPT/typed replies routinely contain curly quotes and en/em
    /// dashes that a hand-built glyph table won't have bespoke entries for
    /// — normalize to the ASCII punctuation the font actually draws rather
    /// than silently dropping them as blanks. Internal (not private): the
    /// chat UI's per-message pixel bubbles run the same replies through the
    /// same font and need the same normalization.
    static func normalize(_ text: String) -> String {
        var result = text
        let map: [(String, String)] = [
            ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
            ("\u{2013}", "-"), ("\u{2014}", "-"),
        ]
        for (from, to) in map { result = result.replacingOccurrences(of: from, with: to) }
        return result
    }

    private static func drawTail(_ ctx: CGContext, bodyRect: CGRect) {
        ctx.setFillColor(BillPalette.black.cgColor)
        let midX = bodyRect.midX
        ctx.fill([
            CGRect(x: midX - 3, y: bodyRect.minY - 2, width: 6, height: 2),
            CGRect(x: midX - 1, y: bodyRect.minY - tailHeight, width: 2, height: tailHeight - 2),
        ])
    }

    /// Rasterizes a rounded rect at unit-pixel granularity: each corner is a
    /// quarter-circle mask (cell kept iff its center falls within `radius`
    /// of the corner's rounding center), everywhere else is a plain filled
    /// cell. This reads as an actual rounded pixel-art corner (a visible
    /// staircase approximating a circle) rather than the single diagonal
    /// chamfer the previous version used, which was too small at this
    /// bubble's size to register as "rounded" at all.
    static func fillPixelRoundedRect(_ ctx: CGContext, rect: CGRect, radius: Int, color: NSColor) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let cols = max(1, Int(rect.width.rounded()))
        let rows = max(1, Int(rect.height.rounded()))
        let r = max(0, min(radius, min(cols, rows) / 2))
        var cells: [CGRect] = []
        cells.reserveCapacity(cols * rows)
        for row in 0..<rows {
            let vCorner = min(row, rows - 1 - row)
            for col in 0..<cols {
                let hCorner = min(col, cols - 1 - col)
                if hCorner < r, vCorner < r {
                    let di = Double(r) - Double(hCorner) - 0.5
                    let dj = Double(r) - Double(vCorner) - 0.5
                    if di * di + dj * dj > Double(r * r) { continue }
                }
                cells.append(CGRect(x: rect.minX + CGFloat(col), y: rect.minY + CGFloat(row), width: 1, height: 1))
            }
        }
        ctx.setFillColor(color.cgColor)
        ctx.fill(cells)
    }

    /// The standard 3-layer pixel bubble border (black outline, colored
    /// accent, white fill) shared by every pixel speech bubble in the app —
    /// Bill's own ambient bark, each stacked chat message, and the
    /// persistent compose bubble — so all three share one visual definition
    /// of "a Bill Cipher speech bubble" instead of near-identical copies.
    /// Returns the innermost (white fill) rect, since callers typically draw
    /// text or host a view centered within it.
    @discardableResult
    static func drawLayeredBorder(_ ctx: CGContext, bodyRect: CGRect, cornerRadius: Int, borderThickness: Int, accentThickness: Int, accentColor: NSColor) -> CGRect {
        fillPixelRoundedRect(ctx, rect: bodyRect, radius: cornerRadius, color: BillPalette.black)
        let accentRect = bodyRect.insetBy(dx: CGFloat(borderThickness), dy: CGFloat(borderThickness))
        fillPixelRoundedRect(ctx, rect: accentRect, radius: max(0, cornerRadius - borderThickness), color: accentColor)
        let fillRect = accentRect.insetBy(dx: CGFloat(accentThickness), dy: CGFloat(accentThickness))
        fillPixelRoundedRect(ctx, rect: fillRect, radius: max(0, cornerRadius - borderThickness - accentThickness), color: NSColor(calibratedWhite: 0.98, alpha: 1))
        return fillRect
    }
}

/// A hand-built 5x7 dot-matrix font. Every glyph is defined as 7 rows of a
/// 5-bit mask (bit 4 = leftmost pixel) via `row(_:)`, which reads directly
/// off the `"##.."`-style strings below — the visual shape in source is the
/// actual glyph shape, so a transcription mistake is easy to spot by eye.
/// No system font/hinting/antialiasing is involved anywhere in this path,
/// which is what guarantees every character has identical, correct
/// proportions at any scale.
@MainActor
enum PixelFont {
    static let glyphWidth: CGFloat = 5
    static let glyphHeight: CGFloat = 7
    /// Gap after a glyph before the next one starts.
    static let glyphSpacing: CGFloat = 1
    static let spaceWidth: CGFloat = 4
    static let lineSpacing: CGFloat = 2
    static let lineHeight: CGFloat = glyphHeight + lineSpacing

    static func advance(for char: Character) -> CGFloat {
        char == " " ? spaceWidth : glyphWidth + glyphSpacing
    }

    /// Rendered width of a line, excluding the trailing spacer after its
    /// last glyph (there's no next character to space out from).
    static func lineWidth(_ line: String) -> CGFloat {
        guard !line.isEmpty else { return 0 }
        let total = line.reduce(CGFloat(0)) { $0 + advance(for: $1) }
        return total - glyphSpacing
    }

    static func pixelRects(for char: Character, originX: CGFloat, originY: CGFloat) -> [CGRect] {
        guard let rows = glyphs[char] else { return [] }
        var rects: [CGRect] = []
        for (rowIndex, bits) in rows.enumerated() {
            let y = originY + glyphHeight - 1 - CGFloat(rowIndex)
            for col in 0..<5 where (bits >> (4 - col)) & 1 == 1 {
                rects.append(CGRect(x: originX + CGFloat(col), y: y, width: 1, height: 1))
            }
        }
        return rects
    }

    /// Renders `lines` as filled unit-pixel rects, each line horizontally
    /// centered in `rect` and the whole block vertically centered — shared
    /// by `BarkBubble` and the chat UI's `PixelMessageBubbleView` so both
    /// draw text with identical metrics off the same glyph table.
    static func drawCentered(_ ctx: CGContext, lines: [String], in rect: CGRect, color: NSColor) {
        ctx.setFillColor(color.cgColor)
        let blockHeight = CGFloat(lines.count) * lineHeight - lineSpacing
        var pixels: [CGRect] = []
        var y = rect.midY + blockHeight / 2
        for line in lines {
            y -= glyphHeight
            let width = lineWidth(line)
            var x = rect.midX - width / 2
            for char in line {
                if char != " " {
                    pixels.append(contentsOf: pixelRects(for: char, originX: x, originY: y))
                }
                x += advance(for: char)
            }
            y -= lineSpacing
        }
        ctx.fill(pixels)
    }

    /// Greedy word-wrap using fixed per-character advances (trivial and
    /// exact, since every glyph has a known fixed width — no font metrics
    /// needed). Caps at `maxLines`, truncating with an ellipsis so a
    /// pathologically long bark can never overflow the character window's
    /// small fixed-size scene (the other half of the "resizing looks
    /// wrong" bug — see `BarkBubble.maxLines`'s doc comment).
    static func wrap(_ text: String, maxWidthUnits: Int, maxLines: Int) -> [String] {
        let maxWidth = CGFloat(maxWidthUnits)
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var lines: [String] = []
        var current = ""
        for word in words {
            // Handled before normal accumulation so a word that's too wide
            // even by itself (a long URL, a run of punctuation) gets broken
            // up regardless of whether it's the first word on the line —
            // folding this into the overflow branch below missed the case
            // where it's also the very first word `current` ever holds.
            let piece = hardBreak(String(word), maxWidth: maxWidth, into: &lines, flushing: &current)
            let candidate = current.isEmpty ? piece : current + " " + piece
            if lineWidth(candidate) > maxWidth, !current.isEmpty {
                lines.append(current)
                current = piece
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        if lines.isEmpty { lines = [""] }

        guard lines.count > maxLines else { return lines }
        var truncated = Array(lines.prefix(maxLines))
        let last = truncated.removeLast()
        var trimmed = last
        while lineWidth(trimmed + "...") > maxWidth, !trimmed.isEmpty {
            trimmed.removeLast()
        }
        truncated.append(trimmed + "...")
        return truncated
    }

    /// A single word wider than the whole bubble on its own (a long URL, a
    /// run of punctuation) gets hard-broken character by character into
    /// `lines` rather than left to overflow — regardless of whether it's
    /// the very first word `current` would ever hold, which is why this
    /// runs before the normal accumulation logic rather than only in its
    /// overflow branch. Flushes whatever `current` already held first (a
    /// long word never merges onto a previous line), then peels off
    /// max-width chunks, leaving the final (guaranteed-fitting) remainder
    /// in `current` for the caller's normal word-wrap loop to keep
    /// accumulating onto.
    private static func hardBreak(_ word: String, maxWidth: CGFloat, into lines: inout [String], flushing current: inout String) -> String {
        guard lineWidth(word) > maxWidth else { return word }
        if !current.isEmpty {
            lines.append(current)
            current = ""
        }
        var chunk = ""
        for char in word {
            let candidate = chunk + String(char)
            if lineWidth(candidate) > maxWidth, !chunk.isEmpty {
                lines.append(chunk)
                chunk = String(char)
            } else {
                chunk = candidate
            }
        }
        return chunk
    }

    private static func row(_ pattern: String) -> UInt8 {
        var value: UInt8 = 0
        for ch in pattern {
            value <<= 1
            if ch == "#" { value |= 1 }
        }
        return value
    }

    private static let glyphs: [Character: [UInt8]] = [
        "A": [row(".###."), row("#...#"), row("#...#"), row("#####"), row("#...#"), row("#...#"), row("#...#")],
        "B": [row("####."), row("#...#"), row("#...#"), row("####."), row("#...#"), row("#...#"), row("####.")],
        "C": [row(".####"), row("#...."), row("#...."), row("#...."), row("#...."), row("#...."), row(".####")],
        "D": [row("####."), row("#...#"), row("#...#"), row("#...#"), row("#...#"), row("#...#"), row("####.")],
        "E": [row("#####"), row("#...."), row("#...."), row("####."), row("#...."), row("#...."), row("#####")],
        "F": [row("#####"), row("#...."), row("#...."), row("####."), row("#...."), row("#...."), row("#....")],
        "G": [row(".####"), row("#...."), row("#...."), row("#.###"), row("#...#"), row("#...#"), row(".####")],
        "H": [row("#...#"), row("#...#"), row("#...#"), row("#####"), row("#...#"), row("#...#"), row("#...#")],
        "I": [row(".###."), row("..#.."), row("..#.."), row("..#.."), row("..#.."), row("..#.."), row(".###.")],
        "J": [row("..###"), row("...#."), row("...#."), row("...#."), row("...#."), row("#..#."), row(".##..")],
        "K": [row("#...#"), row("#..#."), row("#.#.."), row("##..."), row("#.#.."), row("#..#."), row("#...#")],
        "L": [row("#...."), row("#...."), row("#...."), row("#...."), row("#...."), row("#...."), row("#####")],
        "M": [row("#...#"), row("##.##"), row("#.#.#"), row("#...#"), row("#...#"), row("#...#"), row("#...#")],
        "N": [row("#...#"), row("##..#"), row("#.#.#"), row("#..##"), row("#...#"), row("#...#"), row("#...#")],
        "O": [row(".###."), row("#...#"), row("#...#"), row("#...#"), row("#...#"), row("#...#"), row(".###.")],
        "P": [row("####."), row("#...#"), row("#...#"), row("####."), row("#...."), row("#...."), row("#....")],
        "Q": [row(".###."), row("#...#"), row("#...#"), row("#...#"), row("#.#.#"), row("#..#."), row(".##.#")],
        "R": [row("####."), row("#...#"), row("#...#"), row("####."), row("#.#.."), row("#..#."), row("#...#")],
        "S": [row(".####"), row("#...."), row("#...."), row(".###."), row("....#"), row("....#"), row("####.")],
        "T": [row("#####"), row("..#.."), row("..#.."), row("..#.."), row("..#.."), row("..#.."), row("..#..")],
        "U": [row("#...#"), row("#...#"), row("#...#"), row("#...#"), row("#...#"), row("#...#"), row(".###.")],
        "V": [row("#...#"), row("#...#"), row("#...#"), row("#...#"), row("#...#"), row(".#.#."), row("..#..")],
        "W": [row("#...#"), row("#...#"), row("#...#"), row("#.#.#"), row("#.#.#"), row("##.##"), row("#...#")],
        "X": [row("#...#"), row("#...#"), row(".#.#."), row("..#.."), row(".#.#."), row("#...#"), row("#...#")],
        "Y": [row("#...#"), row("#...#"), row(".#.#."), row("..#.."), row("..#.."), row("..#.."), row("..#..")],
        "Z": [row("#####"), row("....#"), row("...#."), row("..#.."), row(".#..."), row("#...."), row("#####")],
        "0": [row(".###."), row("#...#"), row("#..##"), row("#.#.#"), row("##..#"), row("#...#"), row(".###.")],
        "1": [row("..#.."), row(".##.."), row("..#.."), row("..#.."), row("..#.."), row("..#.."), row(".###.")],
        "2": [row(".###."), row("#...#"), row("....#"), row("...#."), row("..#.."), row(".#..."), row("#####")],
        "3": [row("####."), row("....#"), row("....#"), row(".###."), row("....#"), row("....#"), row("####.")],
        "4": [row("...#."), row("..##."), row(".#.#."), row("#..#."), row("#####"), row("...#."), row("...#.")],
        "5": [row("#####"), row("#...."), row("#...."), row("####."), row("....#"), row("....#"), row("####.")],
        "6": [row("..##."), row(".#..."), row("#...."), row("####."), row("#...#"), row("#...#"), row(".###.")],
        "7": [row("#####"), row("....#"), row("...#."), row("..#.."), row("..#.."), row("..#.."), row("..#..")],
        "8": [row(".###."), row("#...#"), row("#...#"), row(".###."), row("#...#"), row("#...#"), row(".###.")],
        "9": [row(".###."), row("#...#"), row("#...#"), row(".####"), row("....#"), row("...#."), row(".##..")],
        ".": [row("....."), row("....."), row("....."), row("....."), row("....."), row(".##.."), row(".##..")],
        ",": [row("....."), row("....."), row("....."), row("....."), row("....."), row("..##."), row(".#...")],
        "!": [row("..#.."), row("..#.."), row("..#.."), row("..#.."), row("..#.."), row("....."), row("..#..")],
        "?": [row(".###."), row("#...#"), row("....#"), row("..##."), row("..#.."), row("....."), row("..#..")],
        "'": [row(".##.."), row(".##.."), row(".#..."), row("....."), row("....."), row("....."), row(".....")],
        "\"": [row("##.##"), row("##.##"), row(".#.#."), row("....."), row("....."), row("....."), row(".....")],
        "-": [row("....."), row("....."), row("....."), row("#####"), row("....."), row("....."), row(".....")],
        ":": [row("....."), row("..#.."), row("..#.."), row("....."), row("..#.."), row("..#.."), row(".....")],
        ";": [row("....."), row("..#.."), row("..#.."), row("....."), row("..#.."), row(".#..."), row(".....")],
        "(": [row("...#."), row("..#.."), row(".#..."), row(".#..."), row(".#..."), row("..#.."), row("...#.")],
        ")": [row(".#..."), row("..#.."), row("...#."), row("...#."), row("...#."), row("..#.."), row(".#...")],
        "/": [row("....#"), row("...#."), row("...#."), row("..#.."), row(".#..."), row(".#..."), row("#....")],
        "*": [row("....."), row("..#.."), row("#.#.#"), row(".###."), row("#.#.#"), row("....."), row(".....")],
        "+": [row("....."), row("..#.."), row("..#.."), row("#####"), row("..#.."), row("..#.."), row(".....")],
        "=": [row("....."), row("....."), row("#####"), row("....."), row("#####"), row("....."), row(".....")],
        "%": [row("#...#"), row("....#"), row("...#."), row("..#.."), row(".#..."), row("#...."), row("#...#")],
        "…": [row("....."), row("....."), row("....."), row("....."), row("....."), row("#.#.#"), row(".....")],
    ]
}
