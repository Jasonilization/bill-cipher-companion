import AppKit

/// AppKit's default `canBecomeKey` for a *borderless* window is `false` —
/// a well-known gotcha that silently breaks keyboard focus for anything
/// inside: `makeFirstResponder` "succeeds" but the window never actually
/// takes key status, so typed keys go nowhere. This is almost certainly why
/// the previous input box couldn't be typed into. Overriding it is the
/// standard fix for a borderless-but-needs-keyboard-input panel.
private final class KeyableBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A small, explicit close affordance. Before this, the only way to dismiss
/// the bubble was clicking outside it or pressing Escape while composing —
/// neither is a visible "this is how you close this" cue, which the
/// exit/close requirement calls for directly. Drawn the same non-antialiased
/// way as the rest of the chrome so it reads as part of the same pixel-art
/// object, not a bolted-on system control. Internal (not private):
/// `PixelMessageBubbleView` reuses this exact control for each per-message
/// dismiss button rather than duplicating it.
final class PixelCloseButton: NSView {
    var onClick: (() -> Void)?
    private var isHovering = false

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(false)

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        let inner = bounds.insetBy(dx: 2, dy: 2)
        ctx.setFillColor((isHovering ? NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.2, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)).cgColor)
        ctx.fill(inner)

        ctx.setFillColor(isHovering ? NSColor.white.cgColor : NSColor.black.cgColor)
        let step: CGFloat = max(1, inner.width / 6)
        var rects: [CGRect] = []
        let count = 4
        for i in 0..<count {
            let f = CGFloat(i)
            rects.append(CGRect(x: inner.minX + step * (f + 1), y: inner.minY + step * (f + 1), width: step, height: step))
            rects.append(CGRect(x: inner.maxX - step * (f + 2), y: inner.minY + step * (f + 1), width: step, height: step))
        }
        ctx.fill(rects)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Plain container for the stacked `PixelMessageBubbleView`s. Flipped so
/// y=0 is the top: the oldest message sits at y=0 and each newer one is
/// placed further down, which puts the newest message at the highest y —
/// i.e. right above the input row, matching "new messages push the older
/// ones upward." Lives inside the scroll view, so once the stack outgrows
/// the screen the oldest messages scroll away instead of clipping the
/// panel off-screen; the document is always its full natural height so
/// scrolling reaches every message.
private final class MessageStackView: NSView {
    override var isFlipped: Bool { true }
}

/// The persistent "compose" bubble — Bill's own pixel speech-bubble style
/// (the same layered border every other bubble in the app uses), but hosting
/// a live `NSTextView` instead of static rendered text. Carries the tail
/// (pointing toward Bill) and the panel-level close button, since it's the
/// one element that's always present regardless of how many messages are
/// stacked above it — there's no separate big background panel anymore for
/// those to live on.
///
/// Sized dynamically from the current typed text (see `updateSize(for:)`)
/// rather than a single fixed bar — a short reply and a long paragraph
/// shouldn't have to compose inside the same oversized box.
private final class PixelInputBubbleView: NSView {
    enum TailSide { case left, right }
    var tailSide: TailSide = .left { didSet { needsDisplay = true } }

    private var bodyWidthUnits: CGFloat = 0
    private var bodyHeightUnits: CGFloat = 0
    /// The composer's wrap ceiling. Internal (set live by `PixelChatBubble`
    /// each layout pass so the Settings width slider applies immediately)
    /// rather than a construction-time `let`.
    var maxTextWidth: CGFloat
    /// Drawn under the (transparent) text view while it's empty, so the box
    /// reads as a place to type into instead of a blank white lozenge.
    var placeholderText: String? { didSet { needsDisplay = true } }
    /// Clicking the box's frame (the padding/border area outside the text
    /// view itself) should still land the caret — routing it through this
    /// hook lets the owner make the text view first responder.
    var onFocusRequest: (() -> Void)?

    private static let pixelScale: CGFloat = PixelMessageBubbleView.pixelScale
    /// Matches the message bubbles' properly-rounded corner (see
    /// `PixelMessageBubbleView.cornerRadius` for the reasoning).
    private static let cornerRadius = 6
    private static let borderThickness = 1
    private static let accentThickness = 1
    private static let paddingX: CGFloat = 10
    private static let paddingY: CGFloat = 6
    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    /// Floor on the composed width — an empty or one-character box would
    /// otherwise shrink to almost nothing, which doesn't read as "type
    /// here" the way a small-but-deliberate box does.
    private static let minTextWidth: CGFloat = 90
    private static let borderInsetPoints = CGFloat(borderThickness + accentThickness) * pixelScale

    init(maxTextWidth: CGFloat) {
        self.maxTextWidth = maxTextWidth
        super.init(frame: .zero)
        updateSize(for: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    /// Recomputes this bubble's size from `text` — the same stateless,
    /// two-pass `boundingRect` measurement `PixelMessageBubbleView` uses
    /// (measure at the max width to find how wide the content wants to be,
    /// then re-measure at that final, possibly-narrower width, since
    /// narrowing can change where lines wrap). Returns whether the size
    /// actually changed, so the caller only needs to relayout the
    /// surrounding panel when it did.
    @discardableResult
    func updateSize(for text: String) -> Bool {
        let oldSize = frame.size
        let sample = text.isEmpty ? " " : text
        // Char-wrapping measurement so a pasted URL/token wider than the
        // box wraps inside it instead of overflowing the bubble's edge
        // (see `PixelMessageBubbleView.attributedString` for the full
        // reasoning — measurement and layout must share the same style).
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let attributed = NSAttributedString(string: sample, attributes: [.font: Self.font, .paragraphStyle: paragraphStyle])

        let wideBounding = attributed.boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textWidth = min(max(ceil(wideBounding.width), Self.minTextWidth), maxTextWidth)

        let finalBounding = attributed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textHeight = max(ceil(finalBounding.height), Self.font.pointSize + 4) + 4

        bodyWidthUnits = (textWidth + Self.paddingX * 2 + Self.borderInsetPoints * 2) / Self.pixelScale
        bodyHeightUnits = (textHeight + Self.paddingY * 2 + Self.borderInsetPoints * 2) / Self.pixelScale

        // No more close-button strip squatting above the text box: the
        // panel now owns a proper header row, so the composer's frame is
        // exactly its own body — less dead space, no cramped look.
        let bodySize = NSSize(width: bodyWidthUnits * Self.pixelScale, height: bodyHeightUnits * Self.pixelScale)
        frame.size = bodySize

        needsDisplay = true
        return frame.size != oldSize
    }

    /// The rect (in this view's own point space) the caller should place
    /// its input text view within — inset from `bounds` to land inside the
    /// drawn border rather than under it.
    var contentRect: NSRect {
        let inset = Self.borderInsetPoints + 2
        return NSRect(x: inset, y: inset, width: bodyWidthUnits * Self.pixelScale - inset * 2, height: bodyHeightUnits * Self.pixelScale - inset * 2)
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: Self.pixelScale, y: Self.pixelScale)

        let bodyRect = CGRect(x: 0, y: 0, width: bodyWidthUnits, height: bodyHeightUnits)
        BarkBubble.drawLayeredBorder(ctx, bodyRect: bodyRect, cornerRadius: Self.cornerRadius, borderThickness: Self.borderThickness, accentThickness: Self.accentThickness, accentColor: BillPalette.bubbleAccent)

        // Blocky tail on whichever edge faces Bill — the same outlined
        // 3-layer treatment as the bark bubble's tail (black outline,
        // accent, fill), rotated to point sideways: part of the border,
        // never a solid black wedge.
        let midY = bodyRect.midY
        switch tailSide {
        case .left:
            // Column 1 flush against the body's left border.
            ctx.setFillColor(BillPalette.black.cgColor)
            ctx.fill([CGRect(x: -1, y: midY - 5, width: 1, height: 10)])
            ctx.setFillColor(BillPalette.bubbleAccent.cgColor)
            ctx.fill([CGRect(x: -1, y: midY - 4, width: 1, height: 8)])
            ctx.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
            ctx.fill([CGRect(x: -1, y: midY - 3, width: 1, height: 6)])
            // Column 2.
            ctx.setFillColor(BillPalette.black.cgColor)
            ctx.fill([CGRect(x: -2, y: midY - 3, width: 1, height: 6)])
            ctx.setFillColor(BillPalette.bubbleAccent.cgColor)
            ctx.fill([CGRect(x: -2, y: midY - 2, width: 1, height: 4)])
            ctx.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
            ctx.fill([CGRect(x: -2, y: midY - 1, width: 1, height: 2)])
            // Column 3: solid black tip.
            ctx.setFillColor(BillPalette.black.cgColor)
            ctx.fill([CGRect(x: -3, y: midY - 1, width: 1, height: 2)])
        case .right:
            ctx.setFillColor(BillPalette.black.cgColor)
            ctx.fill([CGRect(x: bodyRect.width, y: midY - 5, width: 1, height: 10)])
            ctx.setFillColor(BillPalette.bubbleAccent.cgColor)
            ctx.fill([CGRect(x: bodyRect.width, y: midY - 4, width: 1, height: 8)])
            ctx.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
            ctx.fill([CGRect(x: bodyRect.width, y: midY - 3, width: 1, height: 6)])
            ctx.setFillColor(BillPalette.black.cgColor)
            ctx.fill([CGRect(x: bodyRect.width + 1, y: midY - 3, width: 1, height: 6)])
            ctx.setFillColor(BillPalette.bubbleAccent.cgColor)
            ctx.fill([CGRect(x: bodyRect.width + 1, y: midY - 2, width: 1, height: 4)])
            ctx.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
            ctx.fill([CGRect(x: bodyRect.width + 1, y: midY - 1, width: 1, height: 2)])
            ctx.setFillColor(BillPalette.black.cgColor)
            ctx.fill([CGRect(x: bodyRect.width + 2, y: midY - 1, width: 1, height: 2)])
        }
        ctx.restoreGState()

        // Placeholder last, in plain point space (so the font renders at
        // its real size, crisp) and *after* the body fill — drawn before
        // the fill it would be painted over and never visible. Sits exactly
        // where the first typed glyph will land: the text view's content
        // rect (border inset + 2), plus its 5pt default line-fragment
        // padding and 2pt container inset.
        if let placeholderText {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: NSColor.darkGray,
            ]
            let origin = NSPoint(
                x: Self.borderInsetPoints + 2 + 5,
                y: Self.borderInsetPoints + 2 + 2
            )
            (placeholderText as NSString).draw(at: origin, withAttributes: attributes)
        }
    }
}

/// The primary way to talk to Bill: right-click him, choose "Talk", and this
/// small pixel-styled bubble opens beside him — on whichever side of his
/// window has room on screen — instead of the full ChatGPT web UI.
///
/// Holds the conversation as a stack of individual `PixelMessageBubbleView`s
/// (own border, own accent color, own dismiss button) above a persistent
/// input bubble — a loose group of Bill's own speech bubbles floating
/// beside him, not one big panel with a text box glued to it. User and Bill
/// messages are distinguished by accent color and side (Bill left, user
/// right), the same convention as most chat UIs. The stack grows upward as
/// new messages arrive (each popping in); once it would outgrow the
/// screen, the *stack* scrolls inside a bounded panel instead of the panel
/// growing off-screen and clipping older messages for good.
/// The primary way to talk to Bill: right-click him, choose "Talk", and this
/// pixel-styled chat panel opens beside him on whichever side has room.
///
/// Architecturally a deliberate restart: the old version dynamically
/// resized the panel on every message, keystroke, and animation frame —
/// three-plus generations of "cropped by an invisible box" bugs all traced
/// to that geometry fighting itself. This version does what ChatGPT (and
/// every working chat app) does: **a fixed-size panel with scrollable
/// content**. The panel is sized once when opened, positioned once, and
/// never resized during the conversation. Messages scroll, the composer
/// wraps within its bounds, nothing ever exceeds the panel frame.
///
/// The pixel aesthetic lives in the subviews: each message is a
/// `PixelMessageBubbleView` (own layered pixel border, own accent color),
/// the header is `PixelChatHeader` (dot-matrix "BILL", close button,
/// accent rule), and the composer is `PixelInputBubbleView`.
@MainActor
final class PixelChatBubble: NSObject, NSTextViewDelegate {
    private let panel: KeyableBorderlessPanel
    /// Draws the panel's pixel frame — the layered border around the
    /// entire chat, same recipe as every bubble in the app.
    private let frameView = ChatFrameView()
    private let scrollView: NSScrollView
    private let stackView: MessageStackView
    private let header = PixelChatHeader()
    private let inputBubble: PixelInputBubbleView
    private let textView: NSTextView

    private var outsideClickMonitor: Any?

    var onSubmit: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    // MARK: - Fixed geometry

    /// The panel's width in points — user-adjustable via Settings; applies
    /// the next time the chat opens (a fixed panel doesn't live-resize).
    static var panelWidth: CGFloat = 600
    private static let headerHeight: CGFloat = 26
    private static let panelPadding: CGFloat = 8
    private static let bubbleSpacing: CGFloat = 10
    private static let thinkingFrames = ["THINKING.", "THINKING..", "THINKING..."]
    private static let placeholderText = "Talk to Bill…"

    private var messages: [ChatMessage] = []
    private var isComposing = true
    private var thinkingTimer: Timer?
    private var thinkingFrameIndex = 0
    private var thinkingBubbleView: PixelMessageBubbleView?
    private var bubbleViewsByID: [UUID: PixelMessageBubbleView] = [:]
    /// The panel's height, computed once per open from the screen — the
    /// panel fills most of the screen beside Bill, ChatGPT-style.
    private var panelHeight: CGFloat = 520

    // MARK: - Init

    override init() {
        panel = KeyableBorderlessPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.panelWidth, height: 520)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        scrollView = NSScrollView()
        stackView = MessageStackView()
        textView = NSTextView()
        inputBubble = PixelInputBubbleView(maxTextWidth: 520)
        super.init()
        configure()
    }

    private func configure() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        textView.textColor = .black
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 0, height: 2)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        textView.defaultParagraphStyle = paragraphStyle
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false

        inputBubble.onFocusRequest = { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(self.textView)
        }
        inputBubble.placeholderText = Self.placeholderText
        inputBubble.addSubview(textView)

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = stackView

        header.closeButton.onClick = { [weak self] in self?.hide() }
        panel.contentView = frameView
    }

    /// Lays out the panel's children inside its fixed bounds — called once
    /// on open and on `refresh()` (Settings changes). Never called during
    /// normal messaging.
    private func layoutChildren() {
        let bounds = frameView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let contentWidth = bounds.width - Self.panelPadding * 2

        // Top-down: header → scroll (fills middle) → composer.
        header.frame = NSRect(
            x: Self.panelPadding, y: bounds.height - Self.headerHeight,
            width: contentWidth, height: Self.headerHeight
        )

        // The composer wraps to fit inside the panel minus its own chrome.
        inputBubble.maxTextWidth = max(120, contentWidth - 44)

        // The composer's natural height depends on the text typed so far —
        // but it can never exceed half the panel, so the messages always
        // have room. ChatGPT does exactly this: a growing-but-capped
        // input area over a scrollable list.
        let maxComposerHeight = bounds.height * 0.4
        _ = inputBubble.updateSize(for: textView.string)
        var composerHeight = min(inputBubble.frame.height + Self.panelPadding * 2, maxComposerHeight)
        composerHeight = max(composerHeight, 36)

        // Composer at the bottom.
        let composerY = Self.panelPadding
        inputBubble.frame.origin = CGPoint(x: Self.panelPadding, y: composerY)
        inputBubble.frame.size.width = min(inputBubble.frame.width, contentWidth)

        // Scroll fills everything between header and composer.
        let scrollY = composerY + composerHeight + Self.panelPadding
        let scrollHeight = bounds.height - Self.headerHeight - Self.panelPadding - (composerHeight + Self.panelPadding * 2)
        scrollView.frame = NSRect(
            x: Self.panelPadding, y: scrollY,
            width: contentWidth, height: max(0, scrollHeight)
        )

        // The text view inside the composer.
        let content = inputBubble.contentRect
        textView.frame = content
        textView.textContainer?.containerSize = NSSize(width: content.width, height: .greatestFiniteMagnitude)

        // The document view gets the full content width; its height is
        // whatever the messages need.
        let naturalStackHeight = rebuildMessageStack(contentWidth: contentWidth)
        stackView.frame = NSRect(
            x: 0, y: 0,
            width: contentWidth, height: max(naturalStackHeight, scrollView.frame.height)
        )

        // Scroll to the newest message — always, on layout.
        scrollToBottom()

        frameView.addSubview(header)
        frameView.addSubview(scrollView)
        frameView.addSubview(inputBubble)
        frameView.needsDisplay = true
    }

    // MARK: - Message stack

    private func rebuildMessageStack(contentWidth: CGFloat) -> CGFloat {
        var stillNeeded = Set<UUID>()
        var y: CGFloat = 0
        for message in messages {
            stillNeeded.insert(message.id)
            let bubbleView: PixelMessageBubbleView
            if let existing = bubbleViewsByID[message.id] {
                bubbleView = existing
            } else {
                bubbleView = PixelMessageBubbleView(message: message)
                bubbleView.onClose = { [weak self] in self?.removeMessage(id: message.id) }
                bubbleViewsByID[message.id] = bubbleView
                stackView.addSubview(bubbleView)
                Self.popIn(bubbleView)
            }
            let x = message.isFromUser ? contentWidth - bubbleView.frame.width : 0
            bubbleView.frame.origin = CGPoint(x: x, y: y)
            y += bubbleView.frame.height + Self.bubbleSpacing
        }
        for (id, view) in bubbleViewsByID where !stillNeeded.contains(id) {
            view.removeFromSuperview()
            bubbleViewsByID.removeValue(forKey: id)
        }
        if let thinkingBubbleView {
            let x: CGFloat = 0 // Bill's side
            thinkingBubbleView.frame.origin = CGPoint(x: x, y: y)
            y += thinkingBubbleView.frame.height + Self.bubbleSpacing
        }
        return max(0, y - Self.bubbleSpacing)
    }

    /// Always scrolls the newest message into view — the one non-negotiable
    /// behavior of every chat UI.
    private func scrollToBottom() {
        let docHeight = stackView.frame.height
        let clipHeight = scrollView.contentView.bounds.height
        if docHeight > clipHeight {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: docHeight - clipHeight))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private static func popIn(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let frame = view.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        view.frame = frame
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.24
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.4, 0.6, 1)
        layer.add(group, forKey: "popIn")
    }

    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        // Rebuild the stack and scroll — the panel's own frame never
        // changes.
        let contentWidth = scrollView.frame.width
        let naturalStackHeight = rebuildMessageStack(contentWidth: contentWidth)
        stackView.frame.size.height = max(naturalStackHeight, scrollView.frame.height)
        scrollToBottom()
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        bubbleViewsByID.removeValue(forKey: id)?.removeFromSuperview()
        let contentWidth = scrollView.frame.width
        let naturalStackHeight = rebuildMessageStack(contentWidth: contentWidth)
        stackView.frame.size.height = max(naturalStackHeight, scrollView.frame.height)
        scrollToBottom()
    }

    // MARK: - Public API

    var isVisible: Bool { panel.isVisible }

    /// Re-applies Settings changes (accent color, chat width). The panel
    /// stays open; the next message picks up the new numbers.
    func refresh() {
        guard isVisible else { return }
        layoutChildren()
        frameView.needsDisplay = true
    }

    /// Opens the chat panel beside `anchorFrame` — the FIXED-SIZE approach:
    /// one setFrame, one layout, never resized during the conversation.
    func showCompose(near anchorFrame: NSRect, on screen: NSScreen) {
        thinkingTimer?.invalidate()
        beginComposing()
        needsScrollToBottom = true

        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        let width = min(Self.panelWidth, visible.width - 20)
        let height = min(visible.height - 40, visible.height * 0.8)

        // Position: prefer Bill's right, fall back to his left, clamp hard.
        var x: CGFloat
        if anchorFrame.maxX + gap + width <= visible.maxX {
            x = anchorFrame.maxX + gap
        } else if anchorFrame.minX - gap - width >= visible.minX {
            x = anchorFrame.minX - gap - width
        } else {
            x = min(max(anchorFrame.midX - width / 2, visible.minX + 10), visible.maxX - width - 10)
        }
        let y = min(max(anchorFrame.minY, visible.minY + 20), visible.maxY - height - 20)

        // One setFrame. The panel is now a fixed-size floating window —
        // the single most important change: no more per-message,
        // per-keystroke panel resizing, which was the root cause of every
        // "cropped by an invisible box" bug.
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        frameView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        panelHeight = height

        layoutChildren()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        installOutsideClickMonitor()
    }

    private var needsScrollToBottom = true

    private func beginComposing() {
        isComposing = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.textColor = .black
        inputBubble.placeholderText = textView.string.isEmpty ? Self.placeholderText : nil
    }

    func showWaiting(near anchorFrame: NSRect, on screen: NSScreen) {
        isComposing = false
        textView.isEditable = false
        textView.isSelectable = false

        thinkingTimer?.invalidate()
        thinkingFrameIndex = 0
        setThinkingBubble(text: Self.thinkingFrames[0])
        scrollToBottom()
        thinkingTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceThinkingAnimation() }
        }
    }

    private func advanceThinkingAnimation() {
        thinkingFrameIndex += 1
        let text = Self.thinkingFrames[thinkingFrameIndex % Self.thinkingFrames.count]
        if thinkingBubbleView?.update(text: text) == true {
            let contentWidth = scrollView.frame.width
            let naturalStackHeight = rebuildMessageStack(contentWidth: contentWidth)
            stackView.frame.size.height = max(naturalStackHeight, scrollView.frame.height)
            scrollToBottom()
        }
    }

    private func setThinkingBubble(text: String) {
        let bubble = PixelMessageBubbleView(message: ChatMessage(text: text, isFromUser: false), showCloseButton: false)
        stackView.addSubview(bubble)
        thinkingBubbleView = bubble
        Self.popIn(bubble)
    }

    func reanchor(near anchorFrame: NSRect, on screen: NSScreen) {
        guard isVisible else { return }
        // The panel is fixed-size — reanchor just moves it to stay beside
        // Bill. No relayout of the content, no resize.
        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        let size = panel.frame.size
        var x: CGFloat
        if anchorFrame.maxX + gap + size.width <= visible.maxX {
            x = anchorFrame.maxX + gap
        } else if anchorFrame.minX - gap - size.width >= visible.minX {
            x = anchorFrame.minX - gap - size.width
        } else {
            x = min(max(anchorFrame.midX - size.width / 2, visible.minX + 10), visible.maxX - size.width - 10)
        }
        let y = min(max(anchorFrame.minY, visible.minY + 20), visible.maxY - size.height - 20)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showResponse(_ text: String, near anchorFrame: NSRect, on screen: NSScreen) {
        thinkingTimer?.invalidate()
        thinkingBubbleView?.removeFromSuperview()
        thinkingBubbleView = nil
        appendMessage(ChatMessage(text: text, isFromUser: false))
        beginComposing()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func hide() {
        thinkingTimer?.invalidate()
        thinkingBubbleView?.removeFromSuperview()
        thinkingBubbleView = nil
        removeOutsideClickMonitor()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onDismiss?()
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        guard isComposing else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                submit()
            }
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard isComposing else { return }
        inputBubble.placeholderText = textView.string.isEmpty ? Self.placeholderText : nil
        // The composer wraps within the panel; the panel itself never
        // resizes. The scroll area absorbs whatever the composer needs.
        _ = inputBubble.updateSize(for: textView.string)
        inputBubble.frame.origin.y = Self.panelPadding
        let content = inputBubble.contentRect
        textView.frame = content
        textView.textContainer?.containerSize = NSSize(width: content.width, height: .greatestFiniteMagnitude)
    }

    private func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.string = ""
        inputBubble.placeholderText = Self.placeholderText
        inputBubble.updateSize(for: "")
        appendMessage(ChatMessage(text: text, isFromUser: true))
        onSubmit?(text)
    }

    // MARK: - Dismiss on outside click

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isComposing else { return }
                self.hide()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}

/// Draws the chat panel's pixel frame — the layered black/accent/fill
/// border around the entire chat window, the same recipe every bubble in
/// the app uses. The frame is drawn once per size change (which is now
/// "once per open"), not per-message.
private final class ChatFrameView: NSView {
    private static let pixelScale: CGFloat = 2
    private static let borderThickness = 2
    private static let accentThickness = 1

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: Self.pixelScale, y: Self.pixelScale)
        let bodyRect = CGRect(
            x: 0, y: 0,
            width: bounds.width / Self.pixelScale,
            height: bounds.height / Self.pixelScale
        )
        BarkBubble.drawLayeredBorder(
            ctx, bodyRect: bodyRect,
            cornerRadius: 8, borderThickness: Self.borderThickness,
            accentThickness: Self.accentThickness,
            accentColor: BillPalette.bubbleAccent
        )
    }
}
