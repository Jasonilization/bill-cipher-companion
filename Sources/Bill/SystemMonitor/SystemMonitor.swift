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
    private let volume = VolumeMonitor()
    private let clock = ClockMonitor()

    private var lastPowerState: PowerState?
    private var lastNetworkConnected: Bool?
    private var wasCPUHot = false
    private var wasIdle = false
    /// The last 5% step announced, and whether it was announced while
    /// charging — tracked separately so plugging in mid-discharge doesn't
    /// replay the same numbers on the way back up.
    private var lastBatteryBucket: Int?
    private var lastBatteryWasCharging: Bool?
    private var lastVolumeMark: Int?
    private var lastMuted: Bool?

    private static let cpuHotThreshold = 75.0
    private static let idleThreshold: TimeInterval = 300 // 5 minutes
    /// Battery is commented on every 5%.
    private static let batteryStep = 5
    /// A level has to be this far past a step before it counts as crossing —
    /// without it, a battery reading oscillating between 39 and 40 would
    /// re-announce 40 repeatedly.
    private static let batteryHysteresis = 2
    /// The volume marks the user asked to be told about.
    private static let volumeMarks = [0, 25, 50, 75, 100]
    /// How close to a mark counts as hitting it. macOS volume keys move in
    /// 1/16ths (6.25%), so an exact 25/75 is not reachable by keyboard at all
    /// and a tolerance is mandatory, not a nicety.
    private static let volumeMarkTolerance = 4

    func start() {
        appActivity.onAppActivated = { [weak self] bundleID, name, category, pid in
            self?.onEvent?(.appActivated(bundleID: bundleID, name: name, category: category, pid: pid))
        }
        power.onChange = { [weak self] state in
            self?.handlePowerChange(state)
        }
        network.onChange = { [weak self] isConnected in
            self?.handleNetworkChange(isConnected)
        }
        network.onQualityChange = { [weak self] quality in
            self?.onEvent?(.networkQualityChanged(quality))
        }
        volume.onChange = { [weak self] percent, muted in
            self?.handleVolumeChange(percent: percent, muted: muted)
        }
        clock.onHalfHour = { [weak self] hour, minute in
            self?.onEvent?(.halfHour(hour: hour, minute: minute))
        }
        clock.onTimeOfDayChanged = { [weak self] timeOfDay in
            self?.onEvent?(.timeOfDayChanged(timeOfDay))
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
        volume.start()
        clock.start()
        // Establish the volume baseline without announcing it, so the first
        // real change is measured against reality rather than against nothing.
        lastVolumeMark = volume.currentPercent().map(Self.nearestMark)
    }

    func stop() {
        appActivity.stop()
        power.stop()
        network.stop()
        resources.stop()
        volume.stop()
        clock.stop()
    }

    /// Battery handling, rewritten around 5% steps.
    ///
    /// The previous version gated on `state != previous`, and `percentage` is
    /// part of `PowerState`'s synthesised `Equatable` — so every single
    /// percent tick below 20% counted as a change and re-fired `.batteryLow`.
    /// Draining from 20 to 0 produced twenty separate alarms. Now `.batteryLow`
    /// fires once on entering the low band, and the running commentary is
    /// `.batteryLevel`, which only fires on a real 5% step with hysteresis.
    private func handlePowerChange(_ state: PowerState) {
        defer { lastPowerState = state }
        guard let previous = lastPowerState else {
            // First read at launch: seed the bucket so we do not immediately
            // announce wherever the battery happens to already be.
            lastBatteryBucket = state.percentage.map(Self.bucket)
            lastBatteryWasCharging = state.isCharging
            return
        }

        if state.isCharging != previous.isCharging {
            onEvent?(state.isCharging ? .batteryCharging : .batteryUnplugged)
            // Charging state flipped: re-seed so the direction change does not
            // replay steps already announced.
            lastBatteryBucket = state.percentage.map(Self.bucket)
            lastBatteryWasCharging = state.isCharging
            return
        }

        if state.isLow, !previous.isLow {
            onEvent?(.batteryLow(percentage: state.percentage ?? 0))
        }

        guard let percent = state.percentage else { return }
        let bucket = Self.bucket(percent)
        guard let last = lastBatteryBucket else {
            lastBatteryBucket = bucket
            return
        }
        guard bucket != last else { return }
        // Require the reading to be genuinely past the step, not sitting on it.
        let distance = abs(percent - bucket)
        guard distance <= Self.batteryHysteresis || abs(bucket - last) >= Self.batteryStep else { return }
        lastBatteryBucket = bucket
        lastBatteryWasCharging = state.isCharging
        onEvent?(.batteryLevel(percent: bucket, isCharging: state.isCharging))
    }

    private static func bucket(_ percent: Int) -> Int {
        let clamped = min(100, max(0, percent))
        return (clamped / batteryStep) * batteryStep
    }

    private static func nearestMark(_ percent: Int) -> Int {
        volumeMarks.min { abs($0 - percent) < abs($1 - percent) } ?? percent
    }

    private func handleVolumeChange(percent: Int?, muted: Bool) {
        if let lastMuted, lastMuted != muted {
            onEvent?(.volumeMuteChanged(isMuted: muted))
        }
        lastMuted = muted

        guard let percent else { return }
        let mark = Self.nearestMark(percent)
        // Only announce when the level actually lands on (or very near) one of
        // the marks, and only when that mark is different from the last one.
        guard abs(percent - mark) <= Self.volumeMarkTolerance else { return }
        guard mark != lastVolumeMark else { return }
        lastVolumeMark = mark
        onEvent?(.volumeMark(percent: mark))
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
