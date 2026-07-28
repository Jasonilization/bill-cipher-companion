import Network

/// Push-driven via `NWPathMonitor` (the modern replacement for
/// `SCNetworkReachability`, which Apple deprecated in macOS 14.4) — no
/// polling, fires only when connectivity actually changes.
@MainActor
final class NetworkMonitor {
    var onChange: ((Bool) -> Void)?
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "bill.network-monitor")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isConnected = path.status == .satisfied
            Task { @MainActor in
                self?.onChange?(isConnected)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
