import AppKit

/// Push-driven: reports frontmost-app changes via `NSWorkspace` notifications
/// — no polling involved.
@MainActor
final class AppActivityMonitor {
    var onAppActivated: ((_ bundleID: String, _ name: String, _ category: AppCategory?, _ pid: pid_t) -> Void)?
    private var token: NSObjectProtocol?

    func start() {
        stop()
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier
            else { return }
            let name = app.localizedName ?? bundleID
            let category = AppCategoryMapper.category(bundleID: bundleID, bundleURL: app.bundleURL, name: name)
            Task { @MainActor in
                self?.onAppActivated?(bundleID, name, category, app.processIdentifier)
            }
        }
    }

    func stop() {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            self.token = nil
        }
    }
}
