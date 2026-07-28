import Carbon.HIToolbox
import AppKit

/// Registers a single system-wide hotkey (default ⌥⌘Space, to summon/dismiss
/// the chat panel like Spotlight/ChatGPT's classic popup) using the Carbon
/// HIToolbox event manager.
///
/// This is hand-rolled rather than pulled from a package: any SwiftUI-based
/// dependency (even one that merely *offers* a SwiftUI recorder control
/// alongside its core hotkey code) fails to build in this environment — the
/// bare Command Line Tools toolchain here can't find the `SwiftUIMacros`
/// compiler plugin needed to expand `@State`, so any module containing so
/// much as one `@State` property fails, even if we never touch that part of
/// the module. Carbon's C API has no such dependency.
@MainActor
enum GlobalHotKey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var eventHandlerRef: EventHandlerRef?
    private static var handler: (() -> Void)?

    static func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey | cmdKey), onPress: @escaping () -> Void) {
        unregister()
        handler = onPress

        let hotKeyID = EventHotKeyID(signature: OSType(0x42494C4C), id: 1) // 'BILL'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            print("GlobalHotKey: RegisterEventHotKey failed with status \(status)")
            return
        }
        hotKeyRef = ref

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                GlobalHotKey.handler?()
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        eventHandlerRef = handlerRef
    }

    static func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }
}
