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
@MainActor
final class PixelChatBubble: NSObject, NSTextViewDelegate {
    private let panel: KeyableBorderlessPanel
    private let container: NSView
    private let scrollView: NSScrollView
    private let stackView: MessageStackView
    /// The panel's pixel title bar — "BILL" in dot-matrix, close button,
    /// accent rule. Replaces the composer's old dead strip so the
    /// conversation gets the room the strip was wasting.
    private let header = PixelChatHeader()
    private let inputBubble: PixelInputBubbleView
    private let textView: NSTextView

    private var outsideClickMonitor: Any?

    var onSubmit: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    /// Wide — the explicit ask was for a message to spread across most of
    /// the screen rather than staying cramped in a narrow column. Kept
    /// several points larger than `PixelMessageBubbleView.maxTextWidth`'s
    /// own worst-case footprint (520 + its padding/border ≈ 548) rather
    /// than an exact match: an exact fit leaves zero slack for any rounding
    /// difference between the two, which was clipping bubbles against the
    /// panel's own edge. A live `var` (not `let`) — the Settings "chat
    /// bubble width" slider writes it through `AppDelegate` and the next
    /// relayout sizes to it.
    static var maxWidth: CGFloat = 600
    private static let minWidth: CGFloat = 260
    private static let panelPadding: CGFloat = 8
    private static let bubbleSpacing: CGFloat = 10
    private static let thinkingFrames = ["THINKING.", "THINKING..", "THINKING..."]
    private static let resizeAnimationDuration: TimeInterval = 0.22
    private static let placeholderText = "Talk to Bill…"
    /// The slice of the screen the conversation may ever take — beyond this
    /// the stack scrolls instead of letting the panel run off the top or
    /// bottom of the screen (which left older messages unreachable, i.e.
    /// genuinely clipped, once a conversation got long).
    private static let maxStackHeightFraction: CGFloat = 0.72
    /// Fraction of `maxStackHeightFraction` used while no screen is known
    /// yet (first layout before an anchor arrives).
    private static let fallbackScreenHeight: CGFloat = 800

    private var messages: [ChatMessage] = []
    private var isComposing = true
    private var thinkingTimer: Timer?
    private var thinkingFrameIndex = 0
    private var thinkingBubbleView: PixelMessageBubbleView?
    private var bubbleViewsByID: [UUID: PixelMessageBubbleView] = [:]
    private var lastAnchorFrame: NSRect?
    private var lastScreen: NSScreen?
    /// The panel's bottom edge, fixed once per open session so the stack
    /// visibly grows *upward* from a stable base near Bill as messages
    /// arrive, rather than re-centering (and drifting both up and down)
    /// around Bill's frame on every single resize.
    private var anchoredBottomY: CGFloat?
    /// Set whenever something arrives that the user should see immediately
    /// (reopening the bubble, a sent message, the thinking placeholder, a
    /// reply): the next layout pins the scroll to the newest message.
    /// Deliberately *not* set by pure relayouts (typing, a thinking-dots
    /// tick, a dismissal), so the view never yanks the user back down
    /// while they've scrolled up to re-read.
    private var needsScrollToBottom = false

    override init() {
        panel = KeyableBorderlessPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.minWidth, height: 100)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        scrollView = NSScrollView()
        stackView = MessageStackView()
        textView = NSTextView()
        // Matches the message bubbles' live width ceiling (see
        // `PixelMessageBubbleView.maxTextWidth`): same reasoning, plus this
        // bubble's own worst-case chrome so no rounding difference can clip
        // it against the panel's edge. Re-derived every layout pass, so the
        // Settings width slider applies live.
        inputBubble = PixelInputBubbleView(maxTextWidth: 520)
        super.init()
        configure()
    }

    private func configure() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
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
        // Match the measurement style in `updateSize`: without this the
        // text view word-wraps while sizing char-wraps, so a long pasted
        // token measured as "3 lines" renders as 1 overflowing line.
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        textView.defaultParagraphStyle = paragraphStyle
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Both default to `true`, which silently re-clips the container to
        // match `textView.frame` on every reassignment — the same cropping
        // bug already fixed in `PixelMessageBubbleView`, just missed here
        // since this is a separate text view (the composer, not a message).
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false

        inputBubble.onFocusRequest = { [weak self] in
            guard let self else { return }
            panel.makeFirstResponder(textView)
        }
        inputBubble.placeholderText = Self.placeholderText
        inputBubble.addSubview(textView)

        // The stack scrolls once it outgrows its share of the screen rather
        // than growing the panel past the screen edge. Borderless, no
        // background, overlay scroller that hides while idle — visible only
        // when there's genuinely more conversation than fits, so short
        // exchanges look exactly like they did before.
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = stackView

        header.closeButton.onClick = { [weak self] in self?.hide() }
        container.addSubview(scrollView)
        container.addSubview(inputBubble)
        container.addSubview(header)
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }

    /// Re-applies the current geometry/appearance without changing content
    /// — used when a Settings slider (chat width, accent) changes so the
    /// bubble re-wraps to the new numbers instead of waiting for the next
    /// message.
    func refresh() {
        guard isVisible else { return }
        relayoutStack(animated: false)
        container.needsDisplay = true
    }

    /// Opens the bubble beside `anchorFrame` (Bill's character-window frame,
    /// in screen coordinates) on whichever side of `screen` has room, ready
    /// to compose the next message. Whatever conversation is already
    /// stacked from earlier in this app session stays exactly as it was —
    /// closing and reopening the bubble doesn't lose history.
    func showCompose(near anchorFrame: NSRect, on screen: NSScreen) {
        thinkingTimer?.invalidate()
        beginComposing()
        anchoredBottomY = nil
        // Reopening lands on the latest exchange, not the oldest.
        needsScrollToBottom = true
        relayout(near: anchorFrame, on: screen, animated: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        installOutsideClickMonitor()
    }

    private func beginComposing() {
        isComposing = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.textColor = .black
        inputBubble.placeholderText = textView.string.isEmpty ? Self.placeholderText : nil
    }

    /// Appends an animated "Thinking…" placeholder bubble from Bill — called
    /// right after submit so the conversation never looks frozen/dead while
    /// waiting, and a slow reply reads as Bill actively working rather than
    /// nothing happening.
    func showWaiting(near anchorFrame: NSRect, on screen: NSScreen) {
        isComposing = false
        textView.isEditable = false
        textView.isSelectable = false

        thinkingTimer?.invalidate()
        thinkingFrameIndex = 0
        setThinkingBubble(text: Self.thinkingFrames[0])
        needsScrollToBottom = true
        relayout(near: anchorFrame, on: screen, animated: true)
        thinkingTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceThinkingAnimation() }
        }
    }

    private func advanceThinkingAnimation() {
        thinkingFrameIndex += 1
        let text = Self.thinkingFrames[thinkingFrameIndex % Self.thinkingFrames.count]
        if thinkingBubbleView?.update(text: text) == true {
            relayoutStack(animated: false)
        }
    }

    /// Creates the "Thinking…" bubble once per exchange — later ticks update
    /// its text in place (see `advanceThinkingAnimation`) rather than
    /// recreating it, so it doesn't re-play its pop-in entrance every 0.45s.
    private func setThinkingBubble(text: String) {
        let bubble = PixelMessageBubbleView(message: ChatMessage(text: text, isFromUser: false), showCloseButton: false)
        stackView.addSubview(bubble)
        thinkingBubbleView = bubble
        Self.popIn(bubble)
    }

    /// Appends Bill's real reply as a permanent message in the stack,
    /// replacing the transient "Thinking…" placeholder, and immediately
    /// re-opens the input for a follow-up — without this, the bubble went
    /// permanently read-only after the first reply, with no way to keep
    /// the conversation going short of closing and reopening it.
    /// Re-anchors an already-visible bubble to Bill's current position.
    ///
    /// Bill moves — he roams, he gets dragged, and a window can shove him — so
    /// a bubble placed once at open time drifts away from him. The bottom
    /// anchor is deliberately reset here so it re-derives from where he is now
    /// rather than where he was when the conversation started.
    func reanchor(near anchorFrame: NSRect, on screen: NSScreen) {
        guard isVisible else { return }
        anchoredBottomY = nil
        relayout(near: anchorFrame, on: screen, animated: true)
    }

    func showResponse(_ text: String, near anchorFrame: NSRect, on screen: NSScreen) {
        thinkingTimer?.invalidate()
        thinkingBubbleView?.removeFromSuperview()
        thinkingBubbleView = nil
        appendMessage(ChatMessage(text: text, isFromUser: false), near: anchorFrame, on: screen)
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

    // MARK: - Message stack

    private func appendMessage(_ message: ChatMessage, near anchorFrame: NSRect, on screen: NSScreen) {
        messages.append(message)
        needsScrollToBottom = true
        relayout(near: anchorFrame, on: screen, animated: true)
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        bubbleViewsByID.removeValue(forKey: id)?.removeFromSuperview()
        relayoutStack(animated: true)
    }

    /// Positions every bubble from `messages`, creating (and popping in)
    /// only ones that don't already have a view, and smoothly sliding
    /// existing ones to their new spot — so appending one new message
    /// doesn't make the whole conversation flicker or re-animate.
    private func rebuildMessageStack(contentWidth: CGFloat, animated: Bool) -> CGFloat {
        var stillNeeded = Set<UUID>()
        var y: CGFloat = 0
        for message in messages {
            stillNeeded.insert(message.id)
            let bubbleView: PixelMessageBubbleView
            let isNew: Bool
            if let existing = bubbleViewsByID[message.id] {
                bubbleView = existing
                isNew = false
            } else {
                bubbleView = PixelMessageBubbleView(message: message)
                bubbleView.onClose = { [weak self] in self?.removeMessage(id: message.id) }
                bubbleViewsByID[message.id] = bubbleView
                stackView.addSubview(bubbleView)
                isNew = true
            }
            let x = message.isFromUser ? contentWidth - bubbleView.frame.width : 0
            let target = CGPoint(x: x, y: y)
            if isNew {
                bubbleView.frame.origin = target
                Self.popIn(bubbleView)
            } else if animated, bubbleView.frame.origin != target {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.resizeAnimationDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    bubbleView.animator().setFrameOrigin(target)
                }
            } else {
                bubbleView.frame.origin = target
            }
            y += bubbleView.frame.height + Self.bubbleSpacing
        }
        for (id, view) in bubbleViewsByID where !stillNeeded.contains(id) {
            view.removeFromSuperview()
            bubbleViewsByID.removeValue(forKey: id)
        }
        if let thinkingBubbleView {
            // Bill's side — the thinking placeholder is his, and his
            // messages all sit at x:0. Pinning it to the right (the old
            // behaviour) made the placeholder visible-jump across the
            // panel the moment the real reply replaced it.
            thinkingBubbleView.frame.origin = CGPoint(x: 0, y: y)
            y += thinkingBubbleView.frame.height + Self.bubbleSpacing
        }
        return max(0, y - Self.bubbleSpacing)
    }

    /// A quick scale-and-fade entrance for a newly-appeared bubble — the
    /// concrete ask was that new messages should visibly "pop" in as the
    /// stack grows, not just silently appear.
    private static func popIn(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let frame = view.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        view.frame = frame // re-derive layer.position for the new anchor point

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

    // MARK: - Layout

    /// Re-measures and repositions everything using freshly-supplied anchor
    /// info, remembering it so later internal-only updates (a message
    /// dismissed via its own close button, a thinking-dots animation tick)
    /// can relayout without needing a fresh anchor from the caller.
    private func relayout(near anchorFrame: NSRect, on screen: NSScreen, animated: Bool) {
        lastAnchorFrame = anchorFrame
        lastScreen = screen
        relayoutStack(animated: animated)
    }

    private func relayoutStack(animated: Bool) {
        let contentWidth = Self.maxWidth - Self.panelPadding * 2
        // The composer's wrap ceiling must subtract its OWN chrome — the
        // bubble draws ~28pt of border + padding around the text, and the
        // old `contentWidth - 16` let a long line grow the bubble past the
        // panel's edge, where the window's invisible frame cropped it. That
        // was the recurring "cropped by an invisible box" bug in the Talk
        // window: this ceiling is now measured chrome-out, with slack.
        inputBubble.maxTextWidth = max(120, contentWidth - 44)
        let naturalStackHeight = rebuildMessageStack(contentWidth: contentWidth, animated: animated)
        let hasStackContent = naturalStackHeight > 0

        // The stack gets a bounded slice of the screen and scrolls past it,
        // so the panel itself never outgrows the visible frame no matter
        // how long the conversation runs.
        let screenHeight = lastScreen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? Self.fallbackScreenHeight
        let maxStackHeight = max(
            160,
            screenHeight * Self.maxStackHeightFraction
                - inputBubble.frame.height
                - Self.bubbleSpacing
                - header.preferredHeight
                - Self.panelPadding
        )
        let stackHeight = min(naturalStackHeight, maxStackHeight)

        // Bottom-up layout: composer at the floor, the conversation above
        // it, the header on top — each band separated by a comfortable gap
        // rather than the old cramped 8pt everywhere.
        let totalHeight = inputBubble.frame.height
            + (hasStackContent ? Self.bubbleSpacing : 0)
            + stackHeight
            + header.preferredHeight
            + Self.panelPadding
        let size = NSSize(width: Self.maxWidth, height: totalHeight)

        // Decide where the panel lands *before* positioning anything
        // inside: `frame(for:)` picks the tail side (and clamps into the
        // screen, which can flip it), and the input bubble anchors to
        // that same side so it always grows away from Bill.
        let targetFrame: NSRect?
        if let anchorFrame = lastAnchorFrame, let screen = lastScreen {
            targetFrame = frame(for: size, near: anchorFrame, on: screen)
        } else {
            targetFrame = nil
        }

        // Anchored to whichever edge is closer to Bill (matching `tailSide`)
        // so typing more text grows the bubble *away* from him instead of
        // toward/into his window.
        let inputX: CGFloat
        switch inputBubble.tailSide {
        case .left:
            inputX = Self.panelPadding
        case .right:
            inputX = contentWidth + Self.panelPadding - inputBubble.frame.width
        }
        inputBubble.frame.origin = CGPoint(x: inputX, y: 0)
        let stackY = inputBubble.frame.height + (hasStackContent ? Self.bubbleSpacing : 0)
        scrollView.frame = NSRect(x: Self.panelPadding, y: stackY, width: contentWidth, height: stackHeight)
        stackView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(naturalStackHeight, 1))
        header.frame = NSRect(
            x: Self.panelPadding,
            y: stackY + stackHeight + (hasStackContent ? Self.bubbleSpacing : 4),
            width: contentWidth,
            height: header.preferredHeight
        )

        let containerFrame = NSRect(origin: .zero, size: size)
        if let targetFrame {
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.resizeAnimationDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(targetFrame, display: true)
                    container.animator().frame = containerFrame
                }
            } else {
                panel.setFrame(targetFrame, display: true)
                container.frame = containerFrame
            }
        } else {
            panel.setContentSize(size)
            container.frame = containerFrame
        }

        let content = inputBubble.contentRect
        textView.frame = content
        textView.textContainer?.containerSize = NSSize(width: content.width, height: .greatestFiniteMagnitude)

        // Only ever *forward* the scroll to the newest message when
        // something new arrived — never as a side effect of relayout, so
        // re-reading further up is never fought (see `needsScrollToBottom`).
        if needsScrollToBottom {
            needsScrollToBottom = false
            let overflow = stackView.frame.height - scrollView.contentView.bounds.height
            if overflow > 0.5 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: overflow))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    /// Computes the panel's target frame and which side the input bubble's
    /// tail should point. The *bottom* edge is anchored once (see
    /// `anchoredBottomY`) so the panel grows upward from a stable base
    /// near Bill instead of re-centering — and hence drifting both up and
    /// down — around his frame on every single message.
    private func frame(for size: NSSize, near anchorFrame: NSRect, on screen: NSScreen) -> NSRect {
        let gap: CGFloat = 14
        let visible = screen.visibleFrame
        let spaceRight = visible.maxX - anchorFrame.maxX
        let spaceLeft = anchorFrame.minX - visible.minX

        // Prefer Bill's right, fall back to his left — then clamp hard into
        // the visible frame either way. The clamp used to be missing: with
        // Bill near a screen edge and neither flank wide enough for the
        // panel, whichever side "won" simply placed the panel partially
        // off-screen, clipping the conversation. Overlapping Bill's window
        // a little is far better than a chat window you can't fully see.
        var x: CGFloat
        if spaceRight >= size.width + gap || spaceRight >= spaceLeft {
            x = anchorFrame.maxX + gap
        } else {
            x = anchorFrame.minX - gap - size.width
        }
        let minX = visible.minX + 8
        let maxX = max(minX, visible.maxX - size.width - 8)
        x = min(max(x, minX), maxX)
        // Re-derive the tail from where the panel *actually* landed — after
        // clamping it may sit on the opposite side of Bill than the raw
        // space check picked, and a tail pointing away from him looks
        // broken even though the panel is correctly on screen.
        inputBubble.tailSide = (x + size.width / 2) >= anchorFrame.midX ? .left : .right

        let baseBottomY: CGFloat
        if let anchoredBottomY {
            baseBottomY = anchoredBottomY
        } else {
            // Level with Bill, full stop.
            //
            // This used to be `min(anchorFrame.minY, 35% up the screen)`,
            // written when Bill only ever stood near the bottom of the screen.
            // Now that he climbs windows, that `min` pinned the bubble a third
            // of the way up while he was perched near the top — the reported
            // "it glitches to part of the screen". Anchoring to him and letting
            // the on-screen clamp below handle the edges is both simpler and
            // actually correct wherever he happens to be.
            baseBottomY = anchorFrame.minY
            anchoredBottomY = baseBottomY
        }

        // Keep the *top* on screen even if the stack has grown tall — only
        // ever shifts the bottom edge down from its anchor to make room,
        // never up, so it doesn't undo the "grows upward" feel.
        let y = min(baseBottomY, visible.maxY - size.height - 8)
        return NSRect(x: x, y: max(y, visible.minY + 8), width: size.width, height: size.height)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Escape closes the bubble whether or not it's composing — needing
        // to be in the right "mode" for Escape to work made the window
        // feel stuck once a reply was being awaited.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        guard isComposing else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Return sends; Shift+Return is a real newline. Without the
            // Shift path there was no way to write a multi-line message at
            // all, even though the input bubble visibly grows for one.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                submit()
            }
            return true
        }
        return false
    }

    /// Grows/shrinks the input bubble as the user types — setting
    /// `textView.string` directly (as `submit()` does to clear it) doesn't
    /// post this notification, so that path resizes explicitly instead.
    func textDidChange(_ notification: Notification) {
        guard isComposing else { return }
        inputBubble.placeholderText = textView.string.isEmpty ? Self.placeholderText : nil
        guard inputBubble.updateSize(for: textView.string) else { return }
        relayoutStack(animated: false)
    }

    private func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.string = ""
        inputBubble.placeholderText = Self.placeholderText
        inputBubble.updateSize(for: "")
        if let anchorFrame = lastAnchorFrame, let screen = lastScreen {
            appendMessage(ChatMessage(text: text, isFromUser: true), near: anchorFrame, on: screen)
        }
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
