import AppKit
import SwiftUI

@MainActor
final class CharacterWindowController: NSObject {
    private let panel: NSPanel

    override init() {
        let size = NSSize(width: 220, height: 220)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configure(size: size)
    }

    private func configure(size: NSSize) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        // M0 placeholder: nothing interactive yet, so let clicks pass through.
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: PlaceholderBillView())
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.visibleFrame.maxX - size.width - 24,
                y: screen.visibleFrame.minY + 24
            )
            panel.setFrameOrigin(origin)
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }
}

private struct PlaceholderBillView: View {
    var body: some View {
        BillTriangle()
            .fill(Color(red: 1.0, green: 0.85, blue: 0.1))
            .frame(width: 120, height: 120)
            .frame(width: 220, height: 220)
    }
}

private struct BillTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
