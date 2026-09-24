import AppKit
import SwiftUI

/// The first-run "let Bill study your apps" window. SwiftUI content over a
/// plain `NSWindow`/`NSHostingView` — classic `ObservableObject` state only
/// (no macro-based property wrappers; same toolchain constraint as
/// `ChatPanelView`).
@MainActor
final class PersonalizationSetupController: NSObject {
    private var window: NSWindow?
    /// The engine's own model — injected so this window observes the exact
    /// object the flow mutates, never a private copy.
    private let model: PersonalizationModel

    /// Set by `AppDelegate` — starts (or re-runs) the generation flow on
    /// the shared `PersonalizationEngine`.
    var onStart: (() -> Void)?
    /// Set by `AppDelegate` — opens the full ChatGPT panel for sign-in.
    var onOpenLogin: (() -> Void)?
    /// Set by `AppDelegate` — fires whenever the window is presented, so
    /// the intro can show the detected-app list *before* the user commits
    /// to anything (the guided-setup ask).
    var onPresent: (() -> Void)?

    init(model: PersonalizationModel) {
        self.model = model
        super.init()
    }

    func present() {
        onPresent?()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 470)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bill Wants to Study Your Apps"
        window.isReleasedWhenClosed = false
        window.center()
        let hosting = NSHostingView(
            rootView: PersonalizationSetupView(
                model: model,
                onStart: { [weak self] in self?.onStart?() },
                onOpenLogin: { [weak self] in self?.onOpenLogin?() },
                onDone: { [weak self] in self?.window?.orderOut(nil) }
            )
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

/// The flow's content: explain → generate (progress) → done / needs login /
/// failed. Kept deliberately plain — this window is about clarity, not
/// Bill's pixel-art theatrics (he's right there on the desktop being the
/// entertainment).
struct PersonalizationSetupView: View {
    @ObservedObject var model: PersonalizationModel
    var onStart: () -> Void
    var onOpenLogin: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            switch model.phase {
            case .idle, .intro: intro
            case .generating: generating
            case .needsLogin: needsLogin
            case .failed(let reason): failed(reason)
            case .finished(let apps): finished(apps)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 420, height: 470)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text("Personalized commentary")
                    .font(.system(size: 17, weight: .semibold))
                Text("Gravity Falls lines, written for your apps")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bill will use his ChatGPT connection to write himself commentary about the apps on this Mac — a morning line, a midday line, an afternoon line and a night line for each app, plus lines for switching between your most-used apps.")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            if !model.detectedApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apps he can see right now (\(model.detectedApps.count)):")
                        .font(.system(size: 12, weight: .semibold))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.detectedApps, id: \.self) { name in
                                let done = model.studiedApps[name] ?? 0
                                HStack(spacing: 6) {
                                    Image(systemName: done > 0 ? "checkmark.circle.fill" : "circle.dotted")
                                        .font(.system(size: 10))
                                        .foregroundStyle(done > 0 ? Color.green : Color.secondary)
                                    Text(name)
                                        .font(.system(size: 11, design: .monospaced))
                                    Spacer()
                                    if done > 0 {
                                        Text("\(done) lines")
                                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 148)
                    .border(Color.secondary.opacity(0.25))
                }
            }
            Text("Everything is written in his voice, on this machine, through the same chat he talks to you with — and takes a few minutes. You can keep using your Mac while he studies; the Quotes Manager (in Settings) shows every line the moment it lands.")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Text("You'll need to be signed in to ChatGPT in his chat window once.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: onStart) {
                Text("Let Bill Study Your Apps")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private var generating: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(value: max(0.02, model.progress))
            HStack {
                Text(model.statusText.isEmpty ? "Bill is writing…" : model.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.batchCount > 0 {
                    Text("request \(min(model.batchIndex, model.batchCount)) of \(model.batchCount)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if model.appCount > 0 {
                Text("Studying \(model.appCount) apps. Each batch goes live the moment it lands — no need to wait for the finish.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.studiedApps.isEmpty {
                Text("\(model.studiedApps.values.reduce(0, +)) lines written across \(model.studiedApps.count) apps so far — watch them land live in Settings → Quotes Manager.")
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onDone) {
                Text("Hide — Bill keeps studying in the background")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
        }
    }

    private var needsLogin: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bill's embedded ChatGPT page isn't signed in. His browser is separate from yours, so your normal login doesn't carry over — sign in once in the window that just opened, then come back and start again.")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onOpenLogin) {
                Text("Open the ChatGPT Login Page")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Couldn't finish — \(reason)")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Text("Whatever landed before the problem is already active; re-running later tops it up without losing anything.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onStart) {
                Text("Try Again")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private func finished(_ apps: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(apps > 0
                 ? "Done. Bill now has his own lines for \(apps) of your apps — morning, midday, afternoon and night — plus transition quips for your most-used pairs. He's already using them."
                 : "No launchable apps were found to study — Bill will keep his usual commentary.")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Text("Re-run any time from the menu bar — new apps, new lines.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: onDone) {
                Text("Bye!")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }
}
