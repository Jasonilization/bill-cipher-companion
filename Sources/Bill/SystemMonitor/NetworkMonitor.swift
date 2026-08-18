import CoreWLAN
import Foundation
import Network

/// Connectivity *and* link quality.
///
/// Two independent, both push-driven, sources:
///
/// - `NWPathMonitor` for up/down and for interface type / constrained /
///   expensive. This is the authority on "is there a network at all".
/// - `CWWiFiClient`'s `linkQualityDidChange` event for Wi-Fi RSSI and
///   transmit rate. Deliberately the *event* API rather than polling
///   `rssiValue()` on a timer — CoreWLAN pushes these, so watching signal
///   strength costs nothing while the signal is steady.
///
/// Quality is reported as a tier with hysteresis and a dwell time, because a
/// marginal Wi-Fi link crosses any single threshold constantly and Bill
/// announcing that thirty times a minute would be unbearable.
///
/// Degrades silently everywhere: no Wi-Fi interface (ethernet-only, or a Mac
/// with Wi-Fi off) simply means quality is inferred from the path alone.
/// Nothing here needs Location Services — `rssiValue`/`transmitRate` are not
/// gated; only `ssid()`/`bssid()` are, and neither is read.
@MainActor
final class NetworkMonitor {
    var onChange: ((Bool) -> Void)?
    var onQualityChange: ((NetworkQuality) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "bill.network-monitor")
    private var wifiClient: CWWiFiClient?
    private var eventProxy: WiFiEventProxy?

    private var isConnected = true
    private var interfaceIsWired = false
    private var pathIsConstrained = false
    private var latestRSSI: Int?

    private var reportedQuality: NetworkQuality?
    private var pendingQuality: NetworkQuality?
    private var dwellTimer: Timer?

    /// A tier has to hold for this long before it is announced. Long enough
    /// that walking past a microwave doesn't trigger a comment.
    private static let dwellTime: TimeInterval = 25
    /// Hysteresis band, in dBm. A tier boundary has to be cleared by this
    /// much to move *up* a tier, so a signal parked exactly on a threshold
    /// settles instead of oscillating.
    private static let rssiHysteresis = 4

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let wired = path.availableInterfaces.contains { $0.type == .wiredEthernet }
            let constrained = path.isConstrained || path.isExpensive
            Task { @MainActor in
                self?.handlePath(connected: connected, wired: wired, constrained: constrained)
            }
        }
        monitor.start(queue: queue)
        startWiFiEvents()
    }

    func stop() {
        monitor.cancel()
        dwellTimer?.invalidate()
        dwellTimer = nil
        try? wifiClient?.stopMonitoringAllEvents()
        wifiClient?.delegate = nil
        wifiClient = nil
        eventProxy = nil
    }

    // MARK: - Wi-Fi events

    private func startWiFiEvents() {
        let client = CWWiFiClient.shared()
        guard client.interface() != nil else { return }
        let proxy = WiFiEventProxy { [weak self] rssi in
            Task { @MainActor in self?.handleRSSI(rssi) }
        }
        client.delegate = proxy
        try? client.startMonitoringEvent(with: .linkQualityDidChange)
        wifiClient = client
        eventProxy = proxy
        latestRSSI = client.interface()?.rssiValue()
        evaluate()
    }

    private func handleRSSI(_ rssi: Int) {
        // CoreWLAN reports 0 when there is no association.
        latestRSSI = rssi == 0 ? nil : rssi
        evaluate()
    }

    private func handlePath(connected: Bool, wired: Bool, constrained: Bool) {
        let changed = connected != isConnected
        isConnected = connected
        interfaceIsWired = wired
        pathIsConstrained = constrained
        if changed { onChange?(connected) }
        evaluate()
    }

    // MARK: - Tiering

    private func currentQuality() -> NetworkQuality {
        guard isConnected else { return .offline }
        if pathIsConstrained { return .poor }
        if interfaceIsWired { return .excellent }
        guard let rssi = latestRSSI else {
            // Connected, not wired, no Wi-Fi reading — assume it is fine
            // rather than inventing a problem.
            return .good
        }
        // Standard Wi-Fi signal bands, nudged by hysteresis in the direction
        // that makes improving harder than degrading, so recovery is only
        // announced once the link is genuinely better.
        let improving = reportedQuality.map { tierRank($0) } ?? 0
        let bump = improving > 0 ? Self.rssiHysteresis : 0
        switch rssi {
        case (-60 + bump)...:      return .excellent
        case (-72 + bump)..<(-60): return .good
        default:                   return .poor
        }
    }

    private func tierRank(_ q: NetworkQuality) -> Int {
        switch q {
        case .offline: return 0
        case .poor: return 1
        case .good: return 2
        case .excellent: return 3
        }
    }

    private func evaluate() {
        let quality = currentQuality()
        guard quality != reportedQuality else {
            // Back to where we already were — cancel any pending change.
            pendingQuality = nil
            dwellTimer?.invalidate()
            dwellTimer = nil
            return
        }
        // Going offline is not a gradual thing; report it immediately.
        if quality == .offline {
            dwellTimer?.invalidate(); dwellTimer = nil
            pendingQuality = nil
            reportedQuality = quality
            onQualityChange?(quality)
            return
        }
        guard quality != pendingQuality else { return }
        pendingQuality = quality
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: Self.dwellTime, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.commitPending() }
        }
    }

    private func commitPending() {
        dwellTimer = nil
        guard let pending = pendingQuality, pending != reportedQuality else { return }
        // Re-check: the dwell period only counts if it is still true now.
        guard currentQuality() == pending else {
            pendingQuality = nil
            return
        }
        // Suppress the very first report — at launch there is no previous
        // tier to have "changed" from, and announcing the status quo on every
        // login is noise.
        let isFirst = reportedQuality == nil
        reportedQuality = pending
        pendingQuality = nil
        if !isFirst { onQualityChange?(pending) }
    }
}

/// CoreWLAN's event API is `@objc`, so it needs an `NSObject` conformer. Kept
/// as a tiny separate proxy rather than making `NetworkMonitor` itself an
/// `NSObject` subclass, so the monitor stays a plain `@MainActor` type.
private final class WiFiEventProxy: NSObject, CWEventDelegate, @unchecked Sendable {
    private let onRSSI: @Sendable (Int) -> Void

    init(onRSSI: @escaping @Sendable (Int) -> Void) {
        self.onRSSI = onRSSI
    }

    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        onRSSI(rssi)
    }
}
