import SwiftUI
import WebKit

/// The floating chat popup's content: a small header (Bill's status dot +
/// title) over the real chatgpt.com page. Liquid Glass via the real
/// `.glassEffect()` API (this machine is macOS 26+, so we use it directly
/// rather than approximating with `.ultraThinMaterial`).
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
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
        if let page = chatBridge.page {
            WebView(page)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading ChatGPT…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
