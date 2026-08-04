import SwiftUI

/// Read-only debug view of `CharacterWindowController.dialogueRefreshLog` —
/// the daily context refresh runs silently in the background by design, so
/// this is the only way to actually see what was sent, what came back, and
/// what it resulted in.
struct DialogueRefreshLogView: View {
    let entries: [DialogueRefreshLogEntry]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if entries.isEmpty {
                    Text("No refreshes yet. Use \"Refresh Bill's Context Now\" in the menu bar to trigger one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries.reversed()) { entry in
                        entryView(entry)
                        Divider()
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private func entryView(_ entry: DialogueRefreshLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.date.formatted(date: .abbreviated, time: .standard))
                .font(.headline)

            Text("Prompt sent")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.prompt)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            if let failureReason = entry.failureReason {
                Text("⚠️ \(failureReason)")
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }

            if let rawResponse = entry.rawResponse {
                Text("Raw response")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Text(rawResponse)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            if !entry.dialogueLinesAdded.isEmpty {
                Text("Dialogue lines added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(entry.dialogueLinesAdded, id: \.self) { line in
                    Text("• \(line)")
                }
            }

            if !entry.appDescriptionsAdded.isEmpty {
                Text("App descriptions learned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(entry.appDescriptionsAdded, id: \.name) { item in
                    Text("• \(item.name): \(item.description)")
                }
            }
        }
    }
}
