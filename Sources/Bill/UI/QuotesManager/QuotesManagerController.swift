import AppKit
import SwiftUI

/// The quotes manager window — the user's explicit ask: *see* every quote,
/// see which pools are fed by what (authored / generated / personalized),
/// refresh every single quote on demand, and read clear refresh logs.
///
/// ObservableObject-only state (same toolchain constraint as Settings);
/// the library's pools are read live from `DialogueLibrary.shared`.
@MainActor
final class QuotesManagerModel: ObservableObject {
    @Published var selectedKey: String?
    /// Bumped by the refresh button so the list re-reads fresh counts.
    @Published var reloadToken = 0
}

@MainActor
final class QuotesManagerController: NSObject {
    private var window: NSWindow?
    private let model = QuotesManagerModel()

    /// Set by `AppDelegate` — runs the (now every-pool) dialogue refresh.
    var onRefreshAll: (() -> Void)?
    /// Set by `AppDelegate` — shows the full refresh log window.
    var onShowLog: (() -> Void)?
    /// Observed for the recent-log preview strip.
    var refreshStore: DialogueRefreshStore?

    func present() {
        if window == nil {
            let view = QuotesManagerView(
                model: model,
                onRefreshAll: { [weak self] in self?.onRefreshAll?() },
                onShowLog: { [weak self] in self?.onShowLog?() }
            )
            .environmentObject(refreshStore ?? DialogueRefreshStore())
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Quotes Manager"
            win.styleMask = [.titled, .closable, .resizable]
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 760, height: 520))
            window = win
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct QuotesManagerView: View {
    @ObservedObject var model: QuotesManagerModel
    @EnvironmentObject var refreshStore: DialogueRefreshStore
    /// Plain reference, not `@ObservedObject` — `DialogueLibrary` is a
    /// plain @MainActor class; freshness comes from `model.reloadToken`
    /// (bumped by the refresh button) re-driving the computed reads.
    private let library = DialogueLibrary.shared
    var onRefreshAll: () -> Void
    var onShowLog: () -> Void

    private var report: [(key: String, any: Int, morning: Int, midday: Int, afternoon: Int, night: Int, generated: Int)] {
        _ = model.reloadToken
        return library.report()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                poolList
                Divider()
                detail
            }
            Divider()
            recentLogStrip
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("\(report.count) quote pools")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Refresh Every Quote Now") {
                model.reloadToken += 1
                onRefreshAll()
            }
            Button("Show Refresh Log…") { onShowLog() }
        }
        .padding(12)
    }

    private var poolList: some View {
        List(selection: $model.selectedKey) {
            ForEach(report, id: \.key) { row in
                let sources = library.sourceCounts(for: row.key)
                HStack(spacing: 8) {
                    Text(row.key)
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    if sources.authored > 0 { tag("A \(sources.authored)", .blue) }
                    if sources.generated > 0 { tag("G \(sources.generated)", .orange) }
                    if sources.personalized > 0 { tag("P \(sources.personalized)", .purple) }
                    Text("\(library.totalLines(for: row.key))")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .tag(row.key)
            }
        }
        .frame(width: 300)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var detail: some View {
        Group {
            if let key = model.selectedKey {
                let lines = library.poolDetail(key)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(entry.bucket.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                    Text(entry.source)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(
                                            entry.source == "authored" ? .blue
                                                : entry.source == "generated" ? .orange : .purple
                                        )
                                }
                                Text(entry.line)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Pick a pool to read every line, where each one came from, and when it's eligible to be said.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var recentLogStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if refreshStore.entries.isEmpty {
                Text("No refresh has run yet — hit “Refresh Every Quote Now” and watch it land here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(refreshStore.entries.prefix(3)) { entry in
                    Text(entry.summarized)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(entry.failureReason == nil ? .secondary : Color.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
