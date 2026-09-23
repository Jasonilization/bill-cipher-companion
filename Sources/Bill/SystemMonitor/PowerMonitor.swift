import IOKit.ps
import Foundation

struct PowerState: Equatable {
    var isCharging: Bool
    var percentage: Int?

    var isLow: Bool {
        !isCharging && (percentage ?? 100) <= 20
    }
}

/// Push-driven via IOKit's power source notification run loop source — no
/// polling. Fires on any battery/charging change.
@MainActor
final class PowerMonitor {
    var onChange: ((PowerState) -> Void)?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        stop()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                monitor.reportCurrentState()
            }
        }, context)?.takeRetainedValue() else { return }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        reportCurrentState()
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            self.runLoopSource = nil
        }
    }

    private func reportCurrentState() {
        guard let state = Self.currentState() else { return }
        onChange?(state)
    }

    private static func currentState() -> PowerState? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let firstSource = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, firstSource)?.takeUnretainedValue() as? [String: Any]
        else { return nil }

        let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
        let percentage = description[kIOPSCurrentCapacityKey] as? Int
        return PowerState(isCharging: isCharging, percentage: percentage)
    }
}
