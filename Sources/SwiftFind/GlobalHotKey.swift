import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let swiftFindToggleWindow = Notification.Name("SwiftFindToggleWindow")
    static let swiftFindPreviewSelection = Notification.Name("SwiftFindPreviewSelection")
}

/// Registers Option+Space through the native macOS Carbon hot-key API.
/// Unlike an NSEvent global monitor, this does not depend on polling other apps' events.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventCallback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard status == noErr else { return }

        var hotKeyID = EventHotKeyID(signature: 0x53574644, id: 1) // SWFD
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            self.eventHandlerRef = nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    private func toggleWindow() {
        NotificationCenter.default.post(name: .swiftFindToggleWindow, object: nil)
    }

    private static let eventCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        hotKey.toggleWindow()
        return noErr
    }
}
