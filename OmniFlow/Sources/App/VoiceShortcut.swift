import Carbon

/// Carbon hotkeys receive both press and release globally without an Input Monitoring prompt.
@MainActor
final class VoiceShortcut {
    static let shared = VoiceShortcut()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() -> Bool {
        if hotKey != nil { return true }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x4E4C5658, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            Task { @MainActor in
                if pressed { VoiceAssistant.shared.shortcutPressed() }
                else { VoiceAssistant.shared.shortcutReleased() }
            }
            return noErr
        }, events.count, &events, nil, &handler)
        guard installed == noErr else { return false }
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: 0x4E4C5658, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { unregister(); return false }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
