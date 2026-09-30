import Carbon.HIToolbox

/// System-wide hotkeys through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()

    private var actions: [UInt32: () -> Void] = [:]
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// `keyCode` is a `kVK_*` virtual key, `modifiers` a mask of `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5344_7370), id: id) // 'SDsp'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.displays.error("hotkey \(keyCode) registration failed: \(status)")
            return false
        }
        hotKeys.append(ref)
        actions[id] = action
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            Task { @MainActor in HotkeyService.shared.fire(id) }
            return noErr
        }, 1, &eventType, nil, &handler)
    }
}
