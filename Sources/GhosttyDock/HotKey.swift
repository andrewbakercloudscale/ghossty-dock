import Carbon

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no
/// permission and works whichever app is in front.
final class HotKey {
    /// Control-Option-J: jump to the next session that needs you.
    static let jumpKeyCode = UInt32(kVK_ANSI_J)
    static let jumpModifiers = UInt32(controlKey | optionKey)
    static let jumpLabel = "⌃⌥J"

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        Self.handlers[id] = handler
        Self.installHandler()
        let hotKeyId = EventHotKeyID(signature: OSType(0x4744_4B31), id: id) // "GDK1"
        RegisterEventHotKey(keyCode, modifiers, hotKeyId, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKey.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
