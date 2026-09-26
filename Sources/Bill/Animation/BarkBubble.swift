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
    /// relative to another. Internal: `BillStateMachine` needs it to
    /// convert scene-space shifts into tail-offset units.
    static let pixelScale: CGFloat = 3

    /// Live text-size knob from Settings ("size of text box text") —
    /// multiplies the whole bitmap (text *and* its bubble) so everything
    /// stays on one grid. Nearest-neighbor filtering keeps it crisp at
    /// any value. Set by `AppDelegate` from
    /// `AppPreferences.bubbleTextScale`.
    static var textScaleMultiplier: CGFloat = 1

    /// `pixelScale` with the user's text-size knob applied — the number
    /// every point↔unit conversion actually uses.
    static var effectivePixelScale: CGFloat {
        pixelScale * textScaleMultiplier
    }

    // MARK: - Layout grid (all in bubble units)

    private static let paddingX: CGFloat = 7
    private static let paddingY: CGFloat = 6
    /// Properly rounded rather than a near-chamfer — same reasoning as
    /// `PixelMessageBubbleView.cornerRadius`; five units reads as a real
    /// curve at the bark bubble's larger 3x scale.
    private static let cornerRadius = 5
    private static let borderThickness = 1
    private static let accentThickness = 1
    /// The tail is a 3-row outlined trapezoid, not a solid black wedge:
    /// black outline + accent + fill continue down from the body so the
    /// tail reads as part of the border — a proper pixel speech bubble
    /// (the explicit ask).
    private static let tailHeight: CGFloat = 3
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

    /// Which edge of the bubble the tail is drawn on — the directional
    /// speech ask: the bubble sits directly left/right of Bill (tail on
    /// the edge facing him), below him (tail on top), or above (tail on
    /// the bottom, the classic fallback).
    enum TailEdge {
        /// Tail on the bottom edge — bubble floats ABOVE Bill.
        case above
        /// Tail on the top edge — bubble sits BELOW Bill.
        case below
        /// Tail on the left edge — bubble sits to Bill's RIGHT.
        case leftSide
        /// Tail on the right edge — bubble sits to Bill's LEFT.
        case rightSide
    }

    static func makeNode(
        text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat = .greatestFiniteMagnitude,
        tailEdge: TailEdge = .above,
        tailOffsetUnits: CGFloat = 0
    ) -> SKNode {
        // Honor the caller's measured on-screen room: the caller
        // (`BillStateMachine.present`) passes the width of the window's
        // on-screen region so a bubble placed while Bill stands at a
        // screen edge wraps to what's actually visible instead of the
        // full 66-unit column. The parameter used to be accepted and
        // silently ignored, which is how a wide bubble could be placed
        // and then nudged into a region it never fit.
        let chromeUnits = paddingX * 2 + CGFloat(borderThickness + accentThickness) * 2
        let roomUnits = Int((maxWidth / effectivePixelScale).rounded(.down)) - Int(chromeUnits)
        let textColumnUnits = min(maxTextWidthUnits, max(minTextWidthUnits, roomUnits))
        // Height cap: the text-size Settings knob multiplies the whole
        // bitmap, so the old flat 14-line limit could grow a bubble taller
        // than the character window's bark headroom — clipping the top
        // against the window's own edge. The caller passes the *measured*
        // rig-space height it actually has; the line budget shrinks to fit
        // it exactly, whatever the scale.
        let heightBudgetUnits = (maxHeight / effectivePixelScale).rounded(.down) - tailHeight - paddingY * 2
        let lineBudget = max(1, Int(heightBudgetUnits / PixelFont.lineHeight))
        let lines = PixelFont.wrap(
            normalize(text.uppercased()),
            maxWidthUnits: textColumnUnits,
            maxLines: min(maxLines, lineBudget)
        )

        let textBlockWidth = CGFloat(lines.map(PixelFont.lineWidth).max() ?? 0)
        let textBlockHeight = CGFloat(lines.count) * PixelFont.lineHeight - PixelFont.lineSpacing

        let bodyWidth = textBlockWidth + paddingX * 2
        let bodyHeight = textBlockHeight + paddingY * 2
        var imageSize = CGSize(width: bodyWidth, height: bodyHeight)
        var bodyRect: CGRect
        switch tailEdge {
        case .above:
            // Tail rows hang below the body: body sits at the top of the
            // bitmap.
            imageSize.height += tailHeight
            bodyRect = CGRect(x: 0, y: tailHeight, width: bodyWidth, height: bodyHeight)
        case .below:
            // Tail rows rise above the body: body sits at the bottom.
            imageSize.height += tailHeight
            bodyRect = CGRect(x: 0, y: 0, width: bodyWidth, height: bodyHeight)
        case .leftSide:
            // Tail columns extend left of the body.
            imageSize.width += tailHeight
            bodyRect = CGRect(x: tailHeight, y: 0, width: bodyWidth, height: bodyHeight)
        case .rightSide:
            imageSize.width += tailHeight
            bodyRect = CGRect(x: 0, y: 0, width: bodyWidth, height: bodyHeight)
        }

        let image = NSImage(size: imageSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(false)
            ctx.setAllowsAntialiasing(false)
            ctx.interpolationQuality = .none

            let fillRect = drawLayeredBorder(ctx, bodyRect: bodyRect, cornerRadius: cornerRadius, borderThickness: borderThickness, accentThickness: accentThickness, accentColor: BillPalette.bubbleAccent)
            drawTail(ctx, bodyRect: bodyRect, edge: tailEdge, offsetUnits: tailOffsetUnits)
            PixelFont.drawCentered(ctx, lines: lines, in: fillRect, color: BillPalette.black)

            return true
        }

        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest
        let sprite = SKSpriteNode(texture: texture)
        sprite.setScale(effectivePixelScale)
        // Center anchor for every orientation: the placement engine
        // positions the bitmap center explicitly per edge, so one anchor
        // rule serves all four.
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return sprite
    }

    /// Renders the same bubble as an `NSImage` (bitmap units — multiply the
    /// display size by `effectivePixelScale` yourself). Extracted from
    /// `makeNode` so Settings can show a live bubble preview — accent
    /// colour, text scale, corner shape and the outlined tail — without
    /// touching SpriteKit at all.
    static func makePreviewImage(text: String) -> NSImage {
        let lines = PixelFont.wrap(
            normalize(text.uppercased()),
            maxWidthUnits: maxTextWidthUnits,
            maxLines: 6
        )
        let textBlockWidth = CGFloat(lines.map(PixelFont.lineWidth).max() ?? 0)
        let textBlockHeight = CGFloat(lines.count) * PixelFont.lineHeight - PixelFont.lineSpacing
        let bodyWidth = textBlockWidth + paddingX * 2
        let bodyHeight = textBlockHeight + paddingY * 2
        return NSImage(size: CGSize(width: bodyWidth, height: bodyHeight + tailHeight), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(false)
            ctx.setAllowsAntialiasing(false)
            ctx.interpolationQuality = .none
            let bodyRect = CGRect(x: 0, y: tailHeight, width: bodyWidth, height: bodyHeight)
            let fillRect = drawLayeredBorder(ctx, bodyRect: bodyRect, cornerRadius: cornerRadius, borderThickness: borderThickness, accentThickness: accentThickness, accentColor: BillPalette.bubbleAccent)
            drawTail(ctx, bodyRect: bodyRect, edge: .above, offsetUnits: 0)
            PixelFont.drawCentered(ctx, lines: lines, in: fillRect, color: BillPalette.black)
            return true
        }
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

    /// The tail's position along its edge, in bitmap units — zero (the
    /// default) puts it dead center; a non-zero offset slides it toward
    /// wherever Bill actually is when the bubble itself had to be clamped
    /// off-center — the tail points at Bill, not at the bubble's own
    /// middle.
    ///
    /// Every orientation is the same 3-row/3-column outlined trapezoid —
    /// each step is the same 3-layer black/accent/fill stack as the
    /// body's border, narrowing to a solid black tip: the tail is part of
    /// the border, never a solid wedge.
    private static func drawTail(_ ctx: CGContext, bodyRect: CGRect, edge: TailEdge, offsetUnits: CGFloat) {
        let white = NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
        let accent = BillPalette.bubbleAccent.cgColor
        let black = BillPalette.black.cgColor

        func layer(_ midX: CGFloat, _ y: CGFloat, _ blackW: CGFloat, _ accentW: CGFloat, _ fillW: CGFloat) {
            ctx.setFillColor(black)
            ctx.fill([CGRect(x: midX - blackW / 2, y: y, width: blackW, height: 1)])
            ctx.setFillColor(accent)
            ctx.fill([CGRect(x: midX - accentW / 2, y: y, width: accentW, height: 1)])
            ctx.setFillColor(white)
            ctx.fill([CGRect(x: midX - fillW / 2, y: y, width: fillW, height: 1)])
        }

        func layerV(_ midY: CGFloat, _ x: CGFloat, _ blackH: CGFloat, _ accentH: CGFloat, _ fillH: CGFloat) {
            ctx.setFillColor(black)
            ctx.fill([CGRect(x: x, y: midY - blackH / 2, width: 1, height: blackH)])
            ctx.setFillColor(accent)
            ctx.fill([CGRect(x: x, y: midY - accentH / 2, width: 1, height: accentH)])
            ctx.setFillColor(white)
            ctx.fill([CGRect(x: x, y: midY - fillH / 2, width: 1, height: fillH)])
        }

        switch edge {
        case .above:
            // Tail pointing DOWN from the body's bottom edge at Bill below.
            let maxOffset = bodyRect.width / 2 - 5
            let midX = bodyRect.midX + min(max(offsetUnits, -maxOffset), maxOffset)
            layer(midX, bodyRect.minY - 1, 10, 8, 6)
            layer(midX, bodyRect.minY - 2, 6, 4, 2)
            ctx.setFillColor(black)
            ctx.fill([CGRect(x: midX - 1, y: bodyRect.minY - 3, width: 2, height: 1)])
        case .below:
            // Tail pointing UP from the body's top edge at Bill above.
            let maxOffset = bodyRect.width / 2 - 5
            let midX = bodyRect.midX + min(max(offsetUnits, -maxOffset), maxOffset)
            layer(midX, bodyRect.maxY + 1, 10, 8, 6)
            layer(midX, bodyRect.maxY + 2, 6, 4, 2)
            ctx.setFillColor(black)
            ctx.fill([CGRect(x: midX - 1, y: bodyRect.maxY + 3, width: 2, height: 1)])
        case .leftSide:
            // Tail pointing LEFT from the body's left edge.
            let maxOffset = bodyRect.height / 2 - 5
            let midY = bodyRect.midY + min(max(offsetUnits, -maxOffset), maxOffset)
            layerV(midY, bodyRect.minX - 1, 10, 8, 6)
            layerV(midY, bodyRect.minX - 2, 6, 4, 2)
            ctx.setFillColor(black)
            ctx.fill([CGRect(x: bodyRect.minX - 3, y: midY - 1, width: 1, height: 2)])
        case .rightSide:
            // Tail pointing RIGHT from the body's right edge.
            let maxOffset = bodyRect.height / 2 - 5
            let midY = bodyRect.midY + min(max(offsetUnits, -maxOffset), maxOffset)
            layerV(midY, bodyRect.maxX + 1, 10, 8, 6)
            layerV(midY, bodyRect.maxX + 2, 6, 4, 2)
            ctx.setFillColor(black)
            ctx.fill([CGRect(x: bodyRect.maxX + 3, y: midY - 1, width: 1, height: 2)])
        }
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
