import AppKit

/// Keep exit controls available even when a borderless panel has keyboard focus.
@MainActor
class FrameWindow: NSWindow {
    var onQuit: (() -> Void)?
    var onEscape: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "q", let onQuit {
            onQuit()
            return true
        }
        if event.keyCode == 53, modifiers.isEmpty, let onEscape {
            onEscape()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() }
        else { super.cancelOperation(sender) }
    }
}
