import AppKit

/// A single exchange in the conversation: either something the user typed
/// or a reply from Bill. A plain array of these (not a diffed list) backs
/// `PixelChatBubble`'s conversation stack — cheap to append to and rebuild
/// from at the message counts a chat with Bill actually reaches.
struct ChatMessage {
    let id = UUID()
    let text: String
    let isFromUser: Bool
}

/// One message in the conversation stack — a small, self-contained pixel
/// bubble (own layered border, own dismiss button) rather than a shared,
/// ever-changing text box, so a growing conversation reads as a stack of
/// distinct exchanges pushing upward, the way a real chat thread does,
/// instead of one wall of text that gets replaced each turn.
///
/// The *border* reuses `BarkBubble`'s `fillPixelRoundedRect` — the same
/// rounded-corner rasterizer Bill's own ambient speech bubble uses — so a
/// chat exchange reads as part of the same visual object as Bill himself.
/// The *text*, unlike the ambient bark bubble, is a real `NSTextView` in a
/// real (monospaced, mixed-case) system font rather than the hand-built
/// all-caps dot-matrix `PixelFont`: ChatGPT replies routinely include
/// lowercase prose, URLs, and math notation the 5x7 glyph table simply has
/// no characters for at all, and all-caps blocky text is a lot harder to
/// read at paragraph length than a short ambient one-liner. A real text
/// view also gets automatic link detection/clicking and text selection for
/// free. User and Bill messages share the same shape and only differ by
/// accent color (see `userAccent` vs `BillPalette.bodyYellow`), which is
/// enough to tell them apart at a glance without needing a second visual
/// language.
final class PixelMessageBubbleView: NSView {
    private(set) var message: ChatMessage
    private let isFromUser: Bool
    private let showCloseButton: Bool
    private var bodyWidthUnits: CGFloat = 0
    private var bodyHeightUnits: CGFloat = 0
    private let textView: NSTextView
    private let closeButton = PixelCloseButton()
    var onClose: (() -> Void)?

    /// Smaller than `BarkBubble`'s 3x — the border reads as unmistakably
    /// blocky pixel art without the (real-font) text sitting inside it
    /// looking cramped.
    static let pixelScale: CGFloat = 2
    private static let paddingX: CGFloat = 12
    private static let paddingY: CGFloat = 8
    /// Reads as genuinely rounded rather than a small chamfer — the user
    /// flag was "make it look properly rounded," and at radius 3 the
    /// staircase was too short to register as a curve. Six units gives the
    /// corner quarter-circle enough steps to look intentional at this
    /// bubble's size while staying pixel-art.
    private static let cornerRadius = 6
    private static let borderThickness = 1
    private static let accentThickness = 1
    /// Wide enough that a normal ChatGPT paragraph spreads across most of
    /// the screen instead of wrapping into a tall, narrow column — the
    /// direct ask was to let a message "go everywhere on the screen"
    /// rather than staying cramped. 520 is the ceiling; the *effective*
    /// cap also shrinks with the user's chat-bubble-width setting so a
    /// narrowed panel can never have bubbles wider than itself (the panel
    /// padding + bubble chrome are the 36pt of margin).
    private static let absoluteMaxTextWidth: CGFloat = 520
    static var maxTextWidth: CGFloat {
        min(absoluteMaxTextWidth, PixelChatBubble.maxWidth - 36)
    }
    private static let closeButtonSize: CGFloat = 14
    private static let closeGap: CGFloat = 5
    private static let userAccent = NSColor(calibratedRed: 0.36, green: 0.58, blue: 0.86, alpha: 1)
    /// 12pt rather than the old 11 — the cramped complaint: chat replies
    /// are paragraphs, and 11pt mono at 520 columns reads as fine print.
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    /// Black border + accent ring, in points (already multiplied by
    /// `pixelScale`, since the border is drawn in a scaled unit space but
    /// the text view sits in plain point space) — how far the fill area's
    /// true edge is inset from the bubble's outer frame.
    private static let borderInsetPoints = CGFloat(borderThickness + accentThickness) * pixelScale

    /// `showCloseButton` is false for the transient "Thinking…" placeholder
    /// — dismissing "still thinking" isn't a meaningful user action, and
    /// the extra reserved strip for a button that isn't there would just
    /// leave an odd gap above a bubble that's about to be replaced anyway.
    init(message: ChatMessage, showCloseButton: Bool = true) {
        self.message = message
        isFromUser = message.isFromUser
        self.showCloseButton = showCloseButton
        textView = NSTextView()
        super.init(frame: .zero)

        textView.isEditable = false
        textView.isSelectable = true
        textView.alignment = .left
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        // Both default to `true` on a freshly-created text view/container,
        // which means a later `textView.frame` assignment silently resizes
        // the container out from under our own explicit sizing below —
        // this is what was cropping longer, multi-line replies down to
        // just their last visible fragment. Disabling both hands container
        // sizing entirely over to `applyMessage`'s own calculation.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.linkTextAttributes = [.foregroundColor: NSColor(calibratedRed: 0.1, green: 0.25, blue: 0.75, alpha: 1), .underlineStyle: NSUnderlineStyle.single.rawValue]
        addSubview(textView)

        if showCloseButton {
            closeButton.onClick = { [weak self] in self?.onClose?() }
            addSubview(closeButton)
        }

        applyMessage(animatingResize: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    /// Updates the displayed text in place (used for the "Thinking…" dots
    /// cycling) rather than being torn down and recreated — recreating a
    /// transient placeholder every 0.45s would also re-trigger its pop-in
    /// entrance animation every tick, which reads as jittering rather than
    /// "thinking." Returns whether the bubble's size actually changed, so
    /// the caller knows whether a relayout is needed.
    @discardableResult
    func update(text: String) -> Bool {
        let oldSize = frame.size
        message = ChatMessage(text: text, isFromUser: message.isFromUser)
        applyMessage(animatingResize: true)
        return frame.size != oldSize
    }

    /// Measured with `NSAttributedString.boundingRect` — a stateless,
    /// self-contained calculation with no shared layout-manager state that
    /// could go stale between measurements — in two passes: the first, at
    /// `maxTextWidth`, finds how wide the content actually wants to be (so
    /// a short message gets a snug bubble instead of one padded out to the
    /// full max width); the second *re-measures at that narrower final
    /// width* rather than reusing the first pass's height, since narrowing
    /// can change where lines wrap and therefore how tall the text needs
    /// to be. A few points of vertical slack are added on top of the
    /// second pass's own result: `boundingRect` and the text view's actual
    /// TextKit layout don't always agree to the sub-point, and this was
    /// previously tight enough to crop the last line or two.
    private func applyMessage(animatingResize: Bool) {
        let attributed = Self.attributedString(for: message.text)

        let wideBounding = attributed.boundingRect(
            with: NSSize(width: Self.maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textWidth = min(max(ceil(wideBounding.width), 20), Self.maxTextWidth)

        let finalBounding = attributed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textHeight = max(ceil(finalBounding.height), Self.font.pointSize + 4) + 6

        bodyWidthUnits = (textWidth + Self.paddingX * 2 + Self.borderInsetPoints * 2) / Self.pixelScale
        bodyHeightUnits = (textHeight + Self.paddingY * 2 + Self.borderInsetPoints * 2) / Self.pixelScale

        let bodySize = NSSize(width: bodyWidthUnits * Self.pixelScale, height: bodyHeightUnits * Self.pixelScale)
        let topStrip = showCloseButton ? Self.closeButtonSize + Self.closeGap * 2 : 0
        let totalSize = NSSize(width: bodySize.width, height: bodySize.height + topStrip)

        frame.size = totalSize
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributed)
        textView.frame = NSRect(
            x: Self.borderInsetPoints + Self.paddingX,
            y: Self.borderInsetPoints + Self.paddingY,
            width: textWidth,
            height: textHeight
        )

        if showCloseButton {
            closeButton.frame = NSRect(
                x: totalSize.width - Self.closeGap - Self.closeButtonSize,
                y: totalSize.height - Self.closeGap - Self.closeButtonSize,
                width: Self.closeButtonSize,
                height: Self.closeButtonSize
            )
        }
        needsDisplay = true
    }

    private static func attributedString(for text: String) -> NSAttributedString {
        // Explicit rather than relying on the text view's default: wrapped
        // paragraph text reads noticeably worse centered (each line's
        // ragged edges land on both sides instead of lining up on one),
        // which was flagged directly as a readability problem.
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        // Char- rather than word-wrapping: a ChatGPT reply routinely carries
        // a URL or code token wider than the whole bubble, and by-word
        // wrapping cannot break it — it overflows the line and gets cut off
        // by the bubble's own edge (the "text clips off at edges" report).
        // byCharWrapping still prefers whole words; it splits a word only
        // when nothing else fits, and the two-pass measurement below
        // (`boundingRect` honors this same style) stays in agreement with
        // the text view's layout, so the bubble sizes to what actually
        // renders.
        paragraphStyle.lineBreakMode = .byCharWrapping
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraphStyle])
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let fullRange = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: fullRange) {
                guard let url = match.url else { continue }
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: Self.pixelScale, y: Self.pixelScale)

        let bodyRect = CGRect(x: 0, y: 0, width: bodyWidthUnits, height: bodyHeightUnits)
        let accent = isFromUser ? Self.userAccent : BillPalette.bubbleAccent
        BarkBubble.drawLayeredBorder(ctx, bodyRect: bodyRect, cornerRadius: Self.cornerRadius, borderThickness: Self.borderThickness, accentThickness: Self.accentThickness, accentColor: accent)
        ctx.restoreGState()
    }
}
