import Foundation

/// Aggregates every underlying monitor into one `SystemEvent` callback.
/// Everything here is push-driven except two intentionally coarse polls
/// (CPU, idle-time) — see `ResourceMonitor`. This type has no behavior or
/// personality logic of its own; `ReactionRouter` decides what Bill does
/// with these events.
@MainActor
final class SystemMonitor {
    var onEvent: ((SystemEvent) -> Void)?

    private let appActivity = AppActivityMonitor()
    private let power = PowerMonitor()
    private let network = NetworkMonitor()
    private let resources = ResourceMonitor()

    private var lastPowerState: PowerState?
    private var lastNetworkConnected: Bool?
    private var wasCPUHot = false
    private var wasIdle = false

    private static let cpuHotThreshold = 75.0
    private static let idleThreshold: TimeInterval = 300 // 5 minutes

    func start() {
        appActivity.onAppActivated = { [weak self] bundleID, name, category in
            self?.onEvent?(.appActivated(bundleID: bundleID, name: name, category: category))
        }
        power.onChange = { [weak self] state in
            self?.handlePowerChange(state)
        }
        network.onChange = { [weak self] isConnected in
            self?.handleNetworkChange(isConnected)
        }
        resources.onCPUChange = { [weak self] percent in
            self?.handleCPUChange(percent)
        }
        resources.onIdleChange = { [weak self] idleSeconds in
            self?.handleIdleChange(idleSeconds)
        }

        appActivity.start()
        power.start()
        network.start()
        resources.start()
    }

    func stop() {
        appActivity.stop()
        power.stop()
        network.stop()
        resources.stop()
    }

    private func handlePowerChange(_ state: PowerState) {
        defer { lastPowerState = state }
        guard let previous = lastPowerState else { return } // first read at launch, no event
        guard state != previous else { return }

        if state.isLow {
            onEvent?(.batteryLow(percentage: state.percentage ?? 0))
        } else if state.isCharging && !previous.isCharging {
            onEvent?(.batteryCharging)
        } else if !state.isCharging && previous.isCharging {
            onEvent?(.batteryUnplugged)
        }
    }

    private func handleNetworkChange(_ isConnected: Bool) {
        defer { lastNetworkConnected = isConnected }
        guard let last = lastNetworkConnected else { return } // first read at launch, no event
        guard last != isConnected else { return }
        onEvent?(isConnected ? .networkRestored : .networkLost)
    }

    private func handleCPUChange(_ percent: Double) {
        let isHot = percent >= Self.cpuHotThreshold
        guard isHot != wasCPUHot else { return }
        wasCPUHot = isHot
        onEvent?(isHot ? .cpuHot : .cpuNormal)
    }

    private func handleIdleChange(_ idleSeconds: TimeInterval) {
        let isIdle = idleSeconds >= Self.idleThreshold
        guard isIdle != wasIdle else { return }
        wasIdle = isIdle
        onEvent?(isIdle ? .userIdle : .userReturned)
    }
}
