import SwiftUI

/// Live view of the dialogue refresh log.
///
/// Takes the store as an `@ObservedObject` rather than a plain array snapshot.
/// That is the whole fix for "the log doesn't really work": a refresh takes
/// many seconds, so with a snapshot the window opened, showed a prompt with no
/// response, and never changed — you had to close and reopen it to learn
/// anything, and if the refresh had jammed there was nothing to see at all.
struct DialogueRefreshLogView: View {
    @ObservedObject var store: DialogueRefreshStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.entries.isEmpty {
                        Text("No refreshes recorded yet. Use \"Refresh Bill's Context Now\" in the menu bar to trigger one — every attempt is logged here, including ones that fail before sending.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(store.entries.reversed()) { entry in
                            entryView(entry)
                            Divider()
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var header: some View {
        HStack {
            let ok = store.entries.filter(\.succeeded).count
            Text("\(store.entries.count) attempt\(store.entries.count == 1 ? "" : "s") · \(ok) succeeded")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { store.clear() }
                .disabled(store.entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func entryView(_ entry: DialogueRefreshLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: entry.succeeded ? "checkmark.circle.fill"
                                 : entry.failureReason != nil ? "xmark.octagon.fill" : "clock.fill")
                    .foregroundStyle(entry.succeeded ? .green : entry.failureReason != nil ? .red : .orange)
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    .font(.headline)
                Text(entry.trigger)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                if let seconds = entry.durationSeconds {
                    Text(String(format: "%.1fs", seconds))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let failure = entry.failureReason {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !entry.linesAdded.isEmpty {
                section("Lines added (\(entry.linesAdded.count))") {
                    ForEach(entry.linesAdded, id: \.self) { Text("• \($0)").font(.callout) }
                }
            }
            if !entry.appDescriptionsAdded.isEmpty {
                section("App descriptions learned") {
                    ForEach(entry.appDescriptionsAdded, id: \.self) {
                        Text("• \($0.name): \($0.description)").font(.callout)
                    }
                }
            }

            DisclosureGroup("Prompt sent") {
                Text(entry.prompt)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let raw = entry.rawResponse {
                DisclosureGroup("Raw response") {
                    Text(raw)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
