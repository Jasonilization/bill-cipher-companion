import SwiftUI
import WebKit

/// The full chat view — the real chatgpt.com page inside pixel-styled
/// chrome (the same layered border every bubble in the app uses, not
/// Apple's glass effect). On macOS 26+ the page is a SwiftUI
/// `WebView(page:)`; on older systems the bridge's classic `WKWebView`
/// is hosted directly.
///
/// Built without `@State` — this toolchain's Command Line Tools install
/// can't resolve the `SwiftUIMacros` plugin needed to expand macro-based
/// property wrappers, so all dynamic state flows from `ChatBridge`'s
/// classic `ObservableObject`/`@Published` properties.
struct ChatPanelView: View {
    @ObservedObject var chatBridge: ChatBridge
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(width: 420, height: 560)
        .background(PixelPanelBackground())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(chatBridge.isGenerating ? Color.yellow : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            Text("BILL")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if #available(macOS 27, *) {
            if let page = chatBridge.page {
                WebView(page)
            } else {
                loadingView
            }
        } else if let legacy = chatBridge.legacyWebView {
            LegacyWebKitHost(webView: legacy)
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading ChatGPT…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The pixel panel background — the shared `ChatFrameView` wrapped for
/// SwiftUI, so the full chat view gets the same layered pixel border as
/// every bubble in the app.
private struct PixelPanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> ChatFrameView {
        let view = ChatFrameView()
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: ChatFrameView, context: Context) {}
}

/// Hosts the pre-macOS-26 engine inside the SwiftUI panel.
private struct LegacyWebKitHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
