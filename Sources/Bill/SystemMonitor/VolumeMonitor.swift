import CoreAudio
import Foundation

/// Watches the default output device's volume and mute state.
///
/// Fully push-driven — `AudioObjectAddPropertyListenerBlock`, no polling, so
/// this costs literally nothing until the user actually turns a knob.
///
/// Three things here are easy to get wrong and are handled deliberately:
///
/// 1. **The main element often has no volume control.** Plenty of real
///    devices (many USB DACs, HDMI, AirPlay, and aggregate devices) report
///    `false` for `kAudioDevicePropertyVolumeScalar` on
///    `kAudioObjectPropertyElementMain` while still exposing per-channel
///    controls on elements 1 and 2. Reading only the main element makes the
///    monitor look broken on exactly those devices, so it falls back to
///    averaging the channels.
/// 2. **The default device changes.** Plugging in headphones swaps the
///    device out from under us, and listeners are registered per-device, so
///    they have to be torn down and re-registered on
///    `kAudioHardwarePropertyDefaultOutputDevice`.
/// 3. **Some devices expose no software volume at all** (many pro
///    interfaces do their gain in hardware). Those report `nil` forever, and
///    the monitor degrades silently rather than reporting a bogus 0%.
@MainActor
final class VolumeMonitor {
    /// `(percent 0-100, isMuted)`. `percent` is `nil` on devices with no
    /// software volume control.
    var onChange: ((Int?, Bool) -> Void)?

    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var systemListenerBlock: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "bill.volume-monitor")

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func start() {
        stop()
        let context = Unmanaged.passUnretained(self).toOpaque()

        // Re-bind whenever the default output device changes.
        var systemAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let systemBlock: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in
                let monitor = Unmanaged<VolumeMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.bindToDefaultDevice()
                monitor.report()
            }
        }
        systemListenerBlock = systemBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &systemAddress, queue, systemBlock
        )

        bindToDefaultDevice()
    }

    func stop() {
        unbindDevice()
        if let systemBlock = systemListenerBlock {
            var systemAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &systemAddress, queue, systemBlock
            )
            systemListenerBlock = nil
        }
    }

    // MARK: - Device binding

    private func bindToDefaultDevice() {
        unbindDevice()
        guard let device = Self.defaultOutputDevice() else { return }
        deviceID = device

        let context = Unmanaged.passUnretained(self).toOpaque()
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in
                let monitor = Unmanaged<VolumeMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.report()
            }
        }
        deviceListenerBlock = block

        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            // Register on the main element *and* the first two channels: a
            // device that only implements per-channel volume will never
            // notify on the main element, which is the usual reason a volume
            // watcher silently never fires.
            for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
                var addr = Self.address(selector, scope: kAudioObjectPropertyScopeOutput, element: element)
                guard AudioObjectHasProperty(device, &addr) else { continue }
                AudioObjectAddPropertyListenerBlock(device, &addr, queue, block)
            }
        }
    }

    private func unbindDevice() {
        guard deviceID != kAudioObjectUnknown, let block = deviceListenerBlock else {
            deviceID = kAudioObjectUnknown
            deviceListenerBlock = nil
            return
        }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
                var addr = Self.address(selector, scope: kAudioObjectPropertyScopeOutput, element: element)
                guard AudioObjectHasProperty(deviceID, &addr) else { continue }
                AudioObjectRemovePropertyListenerBlock(deviceID, &addr, queue, block)
            }
        }
        deviceID = kAudioObjectUnknown
        deviceListenerBlock = nil
    }

    // MARK: - Reading

    private func report() {
        let percent = Self.volumePercent(of: deviceID)
        let muted = Self.isMuted(deviceID)
        onChange?(percent, muted)
    }

    /// Reads the current level without waiting for a change — used once at
    /// startup to establish the baseline bucket.
    func currentPercent() -> Int? {
        Self.volumePercent(of: deviceID)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func scalar(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = self.address(
            kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            element: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func volumePercent(of device: AudioDeviceID) -> Int? {
        guard device != kAudioObjectUnknown else { return nil }
        if let main = scalar(device, element: kAudioObjectPropertyElementMain) {
            return Int((main * 100).rounded())
        }
        // No main control — average whatever channels do exist.
        let channels = [1, 2].compactMap { scalar(device, element: AudioObjectPropertyElement($0)) }
        guard !channels.isEmpty else { return nil }
        let average = channels.reduce(0, +) / Float32(channels.count)
        return Int((average * 100).rounded())
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var address = self.address(
            kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}
