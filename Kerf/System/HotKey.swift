import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's hot keys, which need no Accessibility permission.
final class HotKey {
    static let space = UInt32(kVK_Space)

    private var reference: EventHotKeyRef?
    private let id: UInt32
    private let action: () -> Void

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.action = action
        Self.actions[id] = action
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B455246), id: id) // "KERF"
        RegisterEventHotKey(keyCode, Self.carbonFlags(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.actions[id] = nil
    }

    private static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Kerf's shortcuts. ⌥ Space opens the island, on Ask when Ask is on; ⌥⇧ Space asks about the
/// selected text and is only taken from other apps while Ask is on.
enum Shortcuts {
    private static var open: HotKey?
    private static var selection: HotKey?

    static func update() {
        if open == nil {
            open = HotKey(keyCode: HotKey.space, modifiers: .option) { IslandManager.current?.openAsk(sendingSelection: false) }
        }
        if !Feature.ask.isOn {
            selection = nil
        } else if selection == nil {
            selection = HotKey(keyCode: HotKey.space, modifiers: [.option, .shift]) { IslandManager.current?.openAsk(sendingSelection: true) }
        }
    }
}
