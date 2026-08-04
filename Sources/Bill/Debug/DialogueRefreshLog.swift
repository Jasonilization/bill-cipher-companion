import Foundation

/// One daily-refresh attempt's full record — purely for the debug log
/// viewer (`DialogueRefreshLogWindowController`), never persisted and never
/// read by any real behavior. Exists because the refresh happens silently
/// in the background by design (see `CharacterWindowController.
/// performDialogueRefresh`'s doc comment), which makes it otherwise
/// impossible to tell what was actually asked, what came back, and what it
/// resulted in without instrumenting the code by hand each time.
struct DialogueRefreshLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let prompt: String
    var rawResponse: String?
    var dialogueLinesAdded: [String] = []
    var appDescriptionsAdded: [(name: String, description: String)] = []
    /// Set when the exchange didn't produce anything usable — e.g. no
    /// response at all (timed out, send failed). `nil` doesn't imply
    /// success on its own; check `rawResponse`/the two arrays above too.
    var failureReason: String?
}
