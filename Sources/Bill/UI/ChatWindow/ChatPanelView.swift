import SwiftUI
import WebKit

/// The floating chat popup's content: a small header (Bill's status dot +
/// title) over the real chatgpt.com page. On macOS 26 that page is a
/// SwiftUI `WebView(page:)`; on older macOS (the deployment target is 14)
/// the bridge owns a classic `WKWebView` instead (see `ChatBridge.
/// legacyWebView`) and this view merely hosts it inside the same chrome.
/// Glass on 26, ultraThinMaterial below — the "old macOS fallback UI".
///
/// Built without `@State` — this toolchain's Command Line Tools install
/// can't resolve the `SwiftUIMacros` plugin needed to expand macro-based
/// property wrappers (confirmed while building this milestone), so all
/// dynamic state here flows from `ChatBridge`'s classic
/// `ObservableObject`/`@Published` properties via `@ObservedObject` instead.
struct ChatPanelView: View {
    @ObservedObject var chatBridge: ChatBridge
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            content
        }
        .frame(width: 420, height: 560)
        .modifier(BubbleChrome())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(chatBridge.isGenerating ? Color.yellow : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            Text("Bill")
                .font(.system(size: 13, weight: .semibold))
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

/// Glass where it exists, `.ultraThinMaterial` where it doesn't — one
/// modifier so the body stays flat.
private struct BubbleChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            content.background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
        }
    }
}

/// Hosts the pre-26 engine inside the SwiftUI panel.
private struct LegacyWebKitHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
