import AppKit

/// A small pixel-styled background for the chat input box — a stepped
/// border (no smooth arcs/rounded corners) drawn with antialiasing off, so
/// it reads as part of the same visual family as Bill and his speech
/// bubble rather than a modern rounded text field floating next to him.
private final class PixelInputBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)

        ctx.addPath(Self.steppedRectPath(bounds, step: 5))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()

        let inner = bounds.insetBy(dx: 3, dy: 3)
        ctx.addPath(Self.steppedRectPath(inner, step: 3))
        ctx.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
        ctx.fillPath()
    }

    private static func steppedRectPath(_ rect: CGRect, step: CGFloat) -> CGPath {
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0 + step, y: y0))
        path.addLine(to: CGPoint(x: x1 - step, y: y0))
        path.addLine(to: CGPoint(x: x1, y: y0 + step))
        path.addLine(to: CGPoint(x: x1, y: y1 - step))
        path.addLine(to: CGPoint(x: x1 - step, y: y1))
        path.addLine(to: CGPoint(x: x0 + step, y: y1))
        path.addLine(to: CGPoint(x: x0, y: y1 - step))
        path.addLine(to: CGPoint(x: x0, y: y0 + step))
        path.closeSubpath()
        return path
    }
}

/// The primary way to talk to Bill: right-click him (or the global hotkey)
/// summons this small pixel input box right next to him, instead of the
/// full ChatGPT web UI. Typing and pressing Return sends through
/// `ChatBridge` exactly as before; the reply comes back in Bill's own
/// speech bubble, not a browser window.
@MainActor
final class PixelChatInputPanel: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let textField: NSTextField
    var onSubmit: ((String) -> Void)?
    /// Fires whenever the panel closes for any reason — submit, Escape, or
    /// losing focus — so a caller pausing something else (Bill's wander
    /// timer) while the box is open has one place to resume it.
    var onDismiss: (() -> Void)?

    override init() {
        let size = NSSize(width: 220, height: 34)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let background = PixelInputBackgroundView(frame: NSRect(origin: .zero, size: size))
        textField = NSTextField(frame: NSRect(x: 8, y: 7, width: size.width - 16, height: 20))
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        textField.textColor = .black
        textField.focusRingType = .none
        textField.placeholderString = "say something…"
        textField.delegate = self
        textField.usesSingleLineMode = true

        background.addSubview(textField)
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    func show(at origin: NSPoint) {
        panel.setFrameOrigin(origin)
        textField.stringValue = ""
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onDismiss?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }

    private func submit() {
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        hide()
        guard !text.isEmpty else { return }
        onSubmit?(text)
    }
}
