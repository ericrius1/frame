import AppKit
import XCTest
@testable import Frame

final class WindowExitTests: XCTestCase {
    func testCommandQIsConsumedAndRequestsQuitExactlyOnce() async throws {
        try await MainActor.run {
            try withUnshownWindow { window in
                var quitRequests = 0
                var escapeRequests = 0
                window.onQuit = { quitRequests += 1 }
                window.onEscape = { escapeRequests += 1 }

                let consumed = window.performKeyEquivalent(with: try keyEvent("q", modifiers: .command,
                                                                              keyCode: 12, window: window))

                XCTAssertTrue(consumed, "The handled event must not fall through to the app menu and quit twice.")
                XCTAssertEqual(quitRequests, 1)
                XCTAssertEqual(escapeRequests, 0)
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    func testCapsLockDoesNotPreventCommandQ() async throws {
        try await MainActor.run {
            try withUnshownWindow { window in
                var quitRequests = 0
                window.onQuit = { quitRequests += 1 }

                let consumed = window.performKeyEquivalent(with: try keyEvent("Q", modifiers: [.command, .capsLock],
                                                                              keyCode: 12, window: window))

                XCTAssertTrue(consumed)
                XCTAssertEqual(quitRequests, 1)
            }
        }
    }

    func testOtherQShortcutsDoNotRequestQuit() async throws {
        try await MainActor.run {
            try withUnshownWindow { window in
                var quitRequests = 0
                window.onQuit = { quitRequests += 1 }
                let combinations: [NSEvent.ModifierFlags] = [[], .shift, .option, .control,
                                                            [.command, .shift], [.command, .option],
                                                            [.command, .control]]
                for modifiers in combinations {
                    _ = window.performKeyEquivalent(with: try keyEvent("q", modifiers: modifiers,
                                                                       keyCode: 12, window: window))
                    XCTAssertEqual(quitRequests, 0, "Unrelated Q shortcut \(modifiers) must stay available.")
                }
            }
        }
    }

    func testEscapeClosesThroughCallbackWithoutRequestingQuit() async throws {
        try await MainActor.run {
            try withUnshownWindow { window in
                var quitRequests = 0
                var escapeRequests = 0
                window.onQuit = { quitRequests += 1 }
                window.onEscape = { escapeRequests += 1 }

                let consumed = window.performKeyEquivalent(with: try keyEvent("\u{1b}", modifiers: [],
                                                                              keyCode: 53, window: window))

                XCTAssertTrue(consumed)
                XCTAssertEqual(escapeRequests, 1)
                XCTAssertEqual(quitRequests, 0)
            }
        }
    }

    func testModifiedEscapeDoesNotTriggerCloseCallback() async throws {
        try await MainActor.run {
            try withUnshownWindow { window in
                var escapeRequests = 0
                window.onEscape = { escapeRequests += 1 }

                _ = window.performKeyEquivalent(with: try keyEvent("\u{1b}", modifiers: .command,
                                                                   keyCode: 53, window: window))

                XCTAssertEqual(escapeRequests, 0)
            }
        }
    }

    func testAppKitCancelOperationInvokesEscapeCallbackOnce() async {
        await MainActor.run {
            withUnshownWindow { window in
                var quitRequests = 0
                var escapeRequests = 0
                window.onQuit = { quitRequests += 1 }
                window.onEscape = { escapeRequests += 1 }

                window.cancelOperation(nil)

                XCTAssertEqual(escapeRequests, 1)
                XCTAssertEqual(quitRequests, 0)
            }
        }
    }

    @MainActor
    private func withUnshownWindow(_ body: (FrameWindow) throws -> Void) rethrows {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let window = FrameWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(window.isVisible)
        try body(window)
    }

    @MainActor
    private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags,
                          keyCode: UInt16, window: NSWindow) throws -> NSEvent {
        // These event values go directly into this process's unshown window method.
        // Nothing is posted to macOS or sent to another application.
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
    }
}
