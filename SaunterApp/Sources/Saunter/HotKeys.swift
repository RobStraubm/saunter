import AppKit
import Carbon.HIToolbox

/// Globale Tastenkuerzel ueber die Carbon-Hotkey-API (braucht keine Freigabe
/// unter "Bedienungshilfen"). Gedrueckt halten loest nur einmal aus.
@MainActor
final class HotKeyCenter {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var downSince: [UInt32: Date] = [:]
    private var handlerRef: EventHandlerRef?

    init() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr else { return err }
            let isDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            MainActor.assumeIsolated { center.handle(id: id, isDown: isDown) }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    @discardableResult
    func register(keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: 0x4C42_4E44, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        actions[id] = action
        return true
    }

    private func handle(id: UInt32, isDown: Bool) {
        guard isDown else {
            downSince[id] = nil
            return
        }
        // Wiederholung beim Gedrueckthalten ignorieren; nach 1 s ohne Loslassen-Event wieder annehmen
        if let since = downSince[id], Date().timeIntervalSince(since) < 1 { return }
        downSince[id] = Date()
        actions[id]?()
    }
}

struct AppShortcut: Identifiable {
    let label: String
    let key: String
    let keyCode: Int
    let action: @MainActor (TreadmillModel) -> Void

    var id: String { label }
    var display: String { "⌃⌥⌘ \(key)" }

    /// ⌃⌥⌘: Rectangle belegt hier ⌃⌥ + Pfeile/Buchstaben und ⌃⌥⌘ ← / →.
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    static let all: [AppShortcut] = [
        AppShortcut(label: "Start / Pause / Weiter", key: "Leertaste", keyCode: kVK_Space) { $0.hotkeyToggle() },
        AppShortcut(label: "Schneller (+0,5 km/h)", key: "↑", keyCode: kVK_UpArrow) { $0.hotkeyStep(0.5) },
        AppShortcut(label: "Langsamer (−0,5 km/h)", key: "↓", keyCode: kVK_DownArrow) { $0.hotkeyStep(-0.5) },
        AppShortcut(label: "Training beenden", key: "E", keyCode: kVK_ANSI_E) { $0.hotkeyStop() },
        AppShortcut(label: "Übersicht öffnen", key: "U", keyCode: kVK_ANSI_U) { _ in
            DistributedNotificationCenter.default().postNotificationName(
                openDashboardNotification, object: nil, userInfo: nil, deliverImmediately: true)
        },
    ]
}
