import AppKit
import Carbon

@MainActor
final class HotkeyManager {
    private var screenshotRef: EventHotKeyRef?
    private var recordingRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onScreenshot: (() -> Void)?
    var onRecording: (() -> Void)?
    private(set) var screenshotAvailable = false
    private(set) var recordingAvailable = false

    func register() {
        unregister()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotkey = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
            guard result == noErr else { return result }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if hotkey.id == 1 { manager.onScreenshot?() }
                if hotkey.id == 2 { manager.onRecording?() }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            screenshotAvailable = false
            recordingAvailable = false
            return
        }
        let signature: OSType = 0x4652414D // FRAM
        screenshotAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &screenshotRef) == noErr
        recordingAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &recordingRef) == noErr
    }

    func unregister() {
        if let screenshotRef { UnregisterEventHotKey(screenshotRef) }
        if let recordingRef { UnregisterEventHotKey(recordingRef) }
        if let handler { RemoveEventHandler(handler) }
        screenshotRef = nil
        recordingRef = nil
        handler = nil
    }

    /// A missing entry means the OS default is enabled.
    var systemScreenshotShortcutEnabled: Bool {
        guard let dictionary = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let shortcut = dictionary["30"] as? [String: Any],
              let enabled = shortcut["enabled"] as? NSNumber else { return true }
        guard enabled.boolValue else { return false }
        guard let value = shortcut["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return true }
        return parameters[1].intValue == Int(kVK_ANSI_4) && parameters[2].intValue == 1_179_648
    }
}
