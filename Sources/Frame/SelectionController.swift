import AppKit

/// A temporary set of transparent windows, one for each attached display.
@MainActor
final class SelectionController {
    var onQuitRequested: (() -> Void)?
    private var windows: [SelectionWindow] = []
    private var completion: ((CaptureRegion?) -> Void)?
    private var keyMonitor: Any?
    private var spaceHeld = false
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var hasActivated = false
    private weak var activeView: SelectionView?

    func select(kind: CaptureKind, completion: @escaping (CaptureRegion?) -> Void) {
        if self.completion != nil { cancel() }
        self.completion = completion
        spaceHeld = false
        hasActivated = NSApp.isActive

        for screen in NSScreen.screens {
            // A non-activating panel can join another app's full-screen Space (a full-screen
            // video, say); a plain window from a background Dock app stays on the desktop Space.
            let window = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false, screen: screen)
            window.hidesOnDeactivate = false
            window.setFrame(screen.frame, display: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.sharingType = .none
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true

            let view = SelectionView(screen: screen, kind: kind)
            view.onBegin = { [weak self, weak view] in
                guard let self, let view else { return }
                self.activeView = view
                self.windows.compactMap { $0.contentView as? SelectionView }.forEach {
                    if $0 !== view { $0.clearSelection() }
                }
                view.window?.makeKey()
                view.setSpaceHeld(self.spaceHeld)
            }
            view.onComplete = { [weak self, weak view] rect in
                guard let self, let view, self.activeView === view else { return }
                self.finish(CaptureRegion(screen: view.captureScreen, rect: rect))
            }
            view.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            window.makeFirstResponder(view)
            windows.append(window)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if event.type == .keyDown, modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "q", let self {
                let requestQuit = self.onQuitRequested
                self.cancel()
                if let requestQuit { requestQuit() }
                else { NSApp.terminate(nil) }
                return nil
            }
            if event.keyCode == 53, event.type == .keyDown {
                self?.cancel()
                return nil
            }
            if event.keyCode == 49, let self {
                self.spaceHeld = event.type == .keyDown
                let view = self.activeView ?? (self.windows.first(where: { $0.isKeyWindow })?.contentView as? SelectionView)
                view?.setSpaceHeld(self.spaceHeld)
                return nil
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.completion != nil else { return }
                self.hasActivated = true
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasActivated else { return }
                self.cancel()
            }
        }

        // Order the overlays in first so activating Frame has a window on the current
        // Space and never switches away from a full-screen app.
        windows.forEach { $0.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        let mouseScreen = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
        mouseScreen?.makeKey()
        hasActivated = hasActivated || NSApp.isActive
        NSCursor.crosshair.set()
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ region: CaptureRegion?) {
        guard let callback = completion else { return }
        completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        spaceHeld = false
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        hasActivated = false
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
        activeView = nil
        NSCursor.arrow.set()
        callback(region)
    }
}

private final class SelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SelectionView: NSView {
    let captureScreen: NSScreen
    private let kind: CaptureKind
    private var drag: SelectionDrag?
    private var spaceHeld = false
    private var selection: CGRect? { drag?.rect }
    private var tracking: NSTrackingArea?
    private let cancelButton = SelectionCancelButton(title: "Cancel", target: nil, action: nil)
    var onBegin: (() -> Void)?
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    init(screen: NSScreen, kind: CaptureKind) {
        captureScreen = screen
        self.kind = kind
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Select an area to \(kind == .screenshot ? "capture" : "record"). Drag a rectangle. Hold Space while dragging to move it. Press Escape to cancel.")
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.appearance = NSAppearance(named: .darkAqua)
        cancelButton.focusRingType = .none
        cancelButton.font = .systemFont(ofSize: 12, weight: .medium)
        let buttonTitle = NSMutableAttributedString(string: "Cancel", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        buttonTitle.append(NSAttributedString(string: "  esc", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]))
        cancelButton.attributedTitle = buttonTitle
        cancelButton.toolTip = "Cancel selection (Esc)"
        cancelButton.setAccessibilityLabel("Cancel selection")
        cancelButton.setAccessibilityHelp("Cancel this screenshot or recording selection. Keyboard shortcut: Escape.")
        addSubview(cancelButton)
        cancelButton.frame = instructionLayout.cancelRect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        cancelButton.frame = instructionLayout.cancelRect
    }

    @objc private func cancelSelection(_ sender: NSButton) { onCancel?() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .cursorUpdate, .mouseMoved, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    private var selectionCursor: NSCursor { drag?.isMoving == true ? .closedHand : .crosshair }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selectionCursor)
        addCursorRect(cancelButton.frame, cursor: .arrow)
    }
    override func cursorUpdate(with event: NSEvent) { cursor(for: event).set() }
    override func mouseMoved(with event: NSEvent) { cursor(for: event).set() }

    private func cursor(for event: NSEvent) -> NSCursor {
        cancelButton.frame.contains(convert(event.locationInWindow, from: nil)) ? .arrow : selectionCursor
    }

    override func mouseDown(with event: NSEvent) {
        // NSButton normally receives its own hit-tested events; this also keeps
        // a forwarded click in the control's frame from starting a rectangle.
        guard !cancelButton.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onBegin?()
        let start = pixelAligned(convert(event.locationInWindow, from: nil))
        drag = SelectionDrag(start: start, bounds: bounds)
        if spaceHeld { drag?.setMoving(true, pointer: start) }
        needsDisplay = true
        selectionCursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        drag?.update(pointer: pixelAligned(convert(event.locationInWindow, from: nil)))
        needsDisplay = true
        selectionCursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard var drag else { return }
        drag.update(pointer: pixelAligned(convert(event.locationInWindow, from: nil)))
        let rect = drag.rect
        self.drag = nil
        NSCursor.crosshair.set()
        guard rect.width >= 8, rect.height >= 8 else {
            clearSelection()
            return
        }
        onComplete?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }

    func clearSelection() {
        drag = nil
        needsDisplay = true
    }

    func setSpaceHeld(_ held: Bool) {
        guard spaceHeld != held else { return }
        spaceHeld = held
        if drag != nil, let window {
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            drag?.setMoving(held, pointer: pixelAligned(point))
            needsDisplay = true
        }
        window?.invalidateCursorRects(for: self)
        selectionCursor.set()
    }

    private func pixelAligned(_ point: CGPoint) -> CGPoint {
        let scale = captureScreen.backingScaleFactor
        return CGPoint(x: (point.x * scale).rounded() / scale,
                       y: (point.y * scale).rounded() / scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        dim.windingRule = .evenOdd
        if let selection, selection.width > 0, selection.height > 0 {
            dim.appendRect(selection)
        }
        NSColor.black.withAlphaComponent(0.38).setFill()
        dim.fill()

        if let selection, selection.width > 0, selection.height > 0 {
            drawSelection(selection)
            drawDimensions(selection)
        }
        drawInstructions()
    }

    private func drawSelection(_ rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.95).setStroke()
        outline.stroke()

        let accent = NSColor(calibratedRed: 0.43, green: 0.94, blue: 0.82, alpha: 1)
        let length = min(13, min(rect.width, rect.height) / 3)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)
        ]
        for (point, dx, dy) in corners {
            let marker = NSBezierPath()
            marker.move(to: CGPoint(x: point.x, y: point.y + length * dy))
            marker.line(to: point)
            marker.line(to: CGPoint(x: point.x + length * dx, y: point.y))
            marker.lineWidth = 3
            marker.lineCapStyle = .square
            accent.setStroke()
            marker.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDimensions(_ rect: CGRect) {
        let scale = captureScreen.backingScaleFactor
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        let string = NSAttributedString(string: "\(width) × \(height) px", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        let size = string.size()
        let pillSize = CGSize(width: size.width + 24, height: 30)
        let x = min(max(rect.midX - pillSize.width / 2, 10), bounds.width - pillSize.width - 10)
        let below = rect.minY - pillSize.height - 12
        let y = below >= 10 ? below : min(rect.maxY + 12, bounds.height - pillSize.height - 10)
        let pill = CGRect(origin: CGPoint(x: x, y: y), size: pillSize)
        NSColor(calibratedWhite: 0.07, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
        string.draw(at: CGPoint(x: pill.minX + 12, y: pill.midY - size.height / 2))
    }

    private struct InstructionLayout {
        let panel: CGRect
        let title: NSAttributedString
        let hint: NSAttributedString
        let titleRect: CGRect
        let hintRect: CGRect
        let cancelRect: CGRect
    }

    private var instructionLayout: InstructionLayout {
        let action = kind == .screenshot ? "Drag to capture" : "Drag to select recording area"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: action, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
        let hint = NSAttributedString(string: "SPACE  to move", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.58),
            .paragraphStyle: paragraph
        ])
        let inset: CGFloat = 18
        let gap: CGFloat = 20
        let buttonSize = CGSize(width: 112, height: 28)
        let desiredWidth = title.size().width + hint.size().width + buttonSize.width + inset * 2 + gap * 2
        let width = min(max(desiredWidth, 390), max(0, bounds.width - 32))
        let compact = desiredWidth > width
        let height: CGFloat = compact ? 72 : 48
        let panel = CGRect(x: bounds.midX - width / 2, y: bounds.maxY - 40 - height, width: width, height: height)
        let rowCenter = compact ? panel.maxY - 21 : panel.midY
        let cancelRect = CGRect(x: panel.maxX - inset - buttonSize.width,
                                y: rowCenter - buttonSize.height / 2,
                                width: buttonSize.width, height: buttonSize.height)
        let titleRect = CGRect(x: panel.minX + inset, y: rowCenter - title.size().height / 2,
                               width: compact ? max(0, cancelRect.minX - gap - panel.minX - inset) : title.size().width,
                               height: title.size().height)
        let hintRect = CGRect(x: compact ? panel.minX + inset : titleRect.maxX + gap,
                              y: compact ? panel.minY + 11 : panel.midY - hint.size().height / 2,
                              width: compact ? max(0, panel.width - inset * 2) : hint.size().width,
                              height: hint.size().height)
        return InstructionLayout(panel: panel, title: title, hint: hint,
                                 titleRect: titleRect, hintRect: hintRect, cancelRect: cancelRect)
    }

    private func drawInstructions() {
        let layout = instructionLayout
        let path = NSBezierPath(roundedRect: layout.panel, xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.07, alpha: 0.93).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.13).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        layout.title.draw(in: layout.titleRect)
        layout.hint.draw(in: layout.hintRect)
    }
}

private final class SelectionCancelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}
