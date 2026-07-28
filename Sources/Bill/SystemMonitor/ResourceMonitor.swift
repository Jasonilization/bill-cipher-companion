import Foundation
import CoreGraphics

/// The one part of the monitor that genuinely has to poll — there is no
/// push notification for "CPU got hot" or "user went idle". Both polls are
/// intentionally coarse (CPU every 10s, idle-check every 30s) and only run
/// while the Mac is awake.
@MainActor
final class ResourceMonitor {
    var onCPUChange: ((Double) -> Void)?
    var onIdleChange: ((TimeInterval) -> Void)?

    private var cpuTimer: Timer?
    private var idleTimer: Timer?
    private var previousTicks: host_cpu_load_info_data_t?

    func start() {
        stop()
        cpuTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleCPU() }
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleIdle() }
        }
        sampleCPU()
        sampleIdle()
    }

    func stop() {
        cpuTimer?.invalidate()
        cpuTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func sampleIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        onIdleChange?(idle)
    }

    private func sampleCPU() {
        guard let ticks = Self.currentCPUTicks() else { return }
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return }

        let userDelta = Double(ticks.cpu_ticks.0 &- previous.cpu_ticks.0)
        let systemDelta = Double(ticks.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idleDelta = Double(ticks.cpu_ticks.2 &- previous.cpu_ticks.2)
        let niceDelta = Double(ticks.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return }

        let busyFraction = (userDelta + systemDelta + niceDelta) / total
        onCPUChange?(busyFraction * 100)
    }

    private static func currentCPUTicks() -> host_cpu_load_info_data_t? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info
    }
}
