import Foundation
import Carbon

private func mindDockHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

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

    guard status == noErr else { return status }
    let triggeredID = hotKeyID.id
    Task { @MainActor in
        HotKeyManager.shared.dispatch(id: triggeredID)
    }
    return noErr
}

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private static let signature: OSType = 0x4D444B31 // 'MDK1'
    private static let quickDropHotKeyID: UInt32 = 1
    private static let toggleDockHotKeyID: UInt32 = 2

    private var eventHandlerRef: EventHandlerRef?
    private var quickDropRef: EventHotKeyRef?
    private var toggleDockRef: EventHotKeyRef?

    var onQuickDrop: (() -> Void)?
    var onToggleEdgeDock: (() -> Void)?

    private init() {}

    func registerDefaultHotKeys() {
        unregisterAll()

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            mindDockHotKeyCallback,
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )

        // Option + Space -> Quick Drop floating bar (zero Accessibility permissions needed)
        let quickDropID = EventHotKeyID(signature: Self.signature, id: Self.quickDropHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            quickDropID,
            GetApplicationEventTarget(),
            0,
            &quickDropRef
        )

        // Option + Shift + Space -> Toggle non-activating Screen-Edge Dock
        let toggleDockID = EventHotKeyID(signature: Self.signature, id: Self.toggleDockHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey | shiftKey),
            toggleDockID,
            GetApplicationEventTarget(),
            0,
            &toggleDockRef
        )
    }

    func unregisterAll() {
        if let quickDropRef {
            UnregisterEventHotKey(quickDropRef)
            self.quickDropRef = nil
        }
        if let toggleDockRef {
            UnregisterEventHotKey(toggleDockRef)
            self.toggleDockRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func dispatch(id: UInt32) {
        switch id {
        case Self.quickDropHotKeyID:
            onQuickDrop?()
        case Self.toggleDockHotKeyID:
            onToggleEdgeDock?()
        default:
            break
        }
    }
}
