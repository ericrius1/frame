import AppKit
import Combine

@MainActor
final class PreviewController {
    var onOpenSettings: (() -> Void)?
    var onQuitRequested: (() -> Void)?
    var onSaveFinished: ((Error?) -> Void)?
    var isSaving: Bool { !savingItems.isEmpty }
    var captureItems: [CaptureItem] { entries.map(\.item) }
    private(set) var isHiddenForCapture = false

    @MainActor private final class Entry {
        let item: CaptureItem
        let content: PreviewContentView
        var displayID: CGDirectDisplayID
        var savedDirectory: URL?
        var savedURL: URL?
        var sharePicker: NSSharingServicePicker?
        init(item: CaptureItem, displayID: CGDirectDisplayID) {
            self.item = item
            self.displayID = displayID
            content = PreviewContentView(item: item)
        }
    }

    @MainActor private final class Shelf {
        let panel: CapturePreviewPanel
        let scrollView: NSScrollView
        let document: NSView
        init(panel: CapturePreviewPanel) {
            self.panel = panel
            scrollView = NSScrollView(frame: .zero)
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScrollElasticity = .automatic
            scrollView.contentView.drawsBackground = false
            document = NSView(frame: .zero) // Unflipped: newest card sits at y = 0.
            scrollView.documentView = document
            panel.contentView = scrollView
        }
    }

    private let settings: CaptureSettings
    private let presentsWindows: Bool
    private let saver = CaptureSaver()
    private var settingsObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var savingItems = Set<UUID>()
    private var entries: [Entry] = [] // Newest first; retained until individually dismissed.
    private var shelves: [CGDirectDisplayID: Shelf] = [:]

    init(settings: CaptureSettings? = nil, presentsWindows: Bool = true) {
        let settings = settings ?? .shared
        self.settings = settings
        self.presentsWindows = presentsWindows
        settingsObserver = settings.$saveDirectory.dropFirst().sink { [weak self] directory in
            guard let self else { return }
            self.entries.forEach { self.updateSaveButton($0, directory: directory) }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layoutShelves(resetScroll: false) }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func show(_ item: CaptureItem, on screen: NSScreen? = nil) {
        guard !entries.contains(where: { $0.item.id == item.id }) else { return }
        let target = screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let entry = Entry(item: item, displayID: Self.displayID(target))
        let id = item.id
        entry.content.onCopy = { [weak self] in self?.copy(id) }
        entry.content.onSave = { [weak self] in self?.save(id) }
        entry.content.onShare = { [weak self] button in self?.share(id, from: button) }
        entry.content.onClose = { [weak self] in self?.dismiss(id) }
        entries.insert(entry, at: 0)
        isHiddenForCapture = false
        updateSaveButton(entry, directory: settings.saveDirectory)
        let shelf = shelves[entry.displayID] ?? makeShelf(displayID: entry.displayID)
        shelf.panel.activeCaptureID = id
        layoutShelves(resetScroll: true, resetDisplayID: entry.displayID)
    }

    func hideForCapture() {
        isHiddenForCapture = true
        shelves.values.forEach { $0.panel.orderOut(nil) }
    }

    func restoreAfterCapture() {
        isHiddenForCapture = false
        layoutShelves(resetScroll: false)
    }

    func dismiss(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.item.id == id }) else { return }
        let displayID = entries[index].displayID
        let neighbors = entries.filter { $0.displayID == displayID }
        if let shelf = shelves[displayID], shelf.panel.activeCaptureID == id,
           let position = neighbors.firstIndex(where: { $0.item.id == id }) {
            shelf.panel.activeCaptureID = position + 1 < neighbors.count
                ? neighbors[position + 1].item.id
                : (position > 0 ? neighbors[position - 1].item.id : nil)
        }
        entries[index].content.removeFromSuperview()
        entries.remove(at: index)
        // A pending save keeps its own file and completion; closing a card never cancels it.
        layoutShelves(resetScroll: false)
    }

    private static func displayID(_ screen: NSScreen?) -> CGDirectDisplayID {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func makeShelf(displayID: CGDirectDisplayID) -> Shelf {
        let panel = CapturePreviewPanel(contentRect: CGRect(origin: .zero, size: PreviewStackLayout.cardSize),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Frame capture previews. Scroll to older captures.")
        let shelf = Shelf(panel: panel)
        shelves[displayID] = shelf
        panel.onCopy = { [weak self, weak panel] in
            if let id = panel?.activeCaptureID { self?.copy(id) }
        }
        panel.onSave = { [weak self, weak panel] in
            if let id = panel?.activeCaptureID { self?.save(id) }
        }
        panel.onDismiss = { [weak self, weak panel] in
            if let id = panel?.activeCaptureID { self?.dismiss(id) }
        }
        panel.onQuit = { [weak self] in self?.onQuitRequested?() }
        panel.onMouseDown = { [weak self, weak shelf] point in
            guard let self, let shelf else { return }
            let location = shelf.document.convert(point, from: nil)
            if let entry = self.entries.first(where: { $0.displayID == displayID && $0.content.frame.contains(location) }) {
                shelf.panel.activeCaptureID = entry.item.id
                self.refreshActiveBorders(in: shelf, displayID: displayID)
            }
        }
        return shelf
    }

    private func layoutShelves(resetScroll: Bool, resetDisplayID: CGDirectDisplayID? = nil) {
        let screens = NSScreen.screens
        let fallback = NSScreen.main ?? screens.first
        let connectedIDs = Set(screens.map { Self.displayID($0) })
        if let fallback {
            for entry in entries where !connectedIDs.contains(entry.displayID) {
                entry.displayID = Self.displayID(fallback)
            }
        }
        let groups = Dictionary(grouping: entries, by: \.displayID)
        for id in Array(shelves.keys) where groups[id] == nil {
            shelves.removeValue(forKey: id)?.panel.close()
        }
        for (id, cards) in groups {
            let shelf = shelves[id] ?? makeShelf(displayID: id)
            let screen = screens.first(where: { Self.displayID($0) == id }) ?? fallback
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = PreviewStackLayout.panelFrame(visibleFrame: visible, count: cards.count)
            let oldOrigin = shelf.scrollView.contentView.bounds.origin
            shelf.document.subviews.forEach { $0.removeFromSuperview() }
            let frames = PreviewStackLayout.cardFrames(count: cards.count)
            for (entry, cardFrame) in zip(cards, frames) {
                entry.content.frame = cardFrame
                shelf.document.addSubview(entry.content)
            }
            shelf.document.setFrameSize(CGSize(width: PreviewStackLayout.cardSize.width,
                                              height: PreviewStackLayout.documentHeight(count: cards.count)))
            shelf.panel.setFrame(frame, display: true)
            shelf.scrollView.frame = CGRect(origin: .zero, size: frame.size)
            shelf.scrollView.tile()
            if !cards.contains(where: { $0.item.id == shelf.panel.activeCaptureID }) {
                shelf.panel.activeCaptureID = cards.first?.item.id
            }
            refreshActiveBorders(in: shelf, displayID: id)
            let maxY = max(0, shelf.document.frame.height - shelf.scrollView.contentView.bounds.height)
            let reset = resetScroll && (resetDisplayID == nil || resetDisplayID == id)
            let origin = reset ? CGPoint.zero : CGPoint(x: 0, y: min(max(0, oldOrigin.y), maxY))
            shelf.scrollView.contentView.scroll(to: origin)
            shelf.scrollView.reflectScrolledClipView(shelf.scrollView.contentView)
            if presentsWindows && !isHiddenForCapture { shelf.panel.orderFrontRegardless() }
        }
    }

    private func refreshActiveBorders(in shelf: Shelf, displayID: CGDirectDisplayID) {
        for entry in entries where entry.displayID == displayID {
            entry.content.layer?.borderColor = (entry.item.id == shelf.panel.activeCaptureID
                ? NSColor(red: 0.43, green: 0.91, blue: 0.77, alpha: 0.45)
                : NSColor.white.withAlphaComponent(0.15)).cgColor
        }
    }

    private func copy(_ id: UUID) {
        guard let entry = entries.first(where: { $0.item.id == id }) else { return }
        let item = entry.item
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let value = NSPasteboardItem()
        value.setString(item.url.absoluteString, forType: .fileURL)
        if item.kind == .screenshot, let data = try? Data(contentsOf: item.url) {
            value.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation { value.setData(tiff, forType: .tiff) }
        }
        pasteboard.writeObjects([value])
        entry.content.copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak entry] in
            entry?.content.copyButton.title = "Copy"
        }
    }

    func save(_ id: UUID) {
        guard let entry = entries.first(where: { $0.item.id == id }), !savingItems.contains(id) else { return }
        let item = entry.item
        let directory = settings.saveDirectory
        savingItems.insert(id)
        updateSaveButton(entry, directory: directory)
        Task { [weak self, saver] in
            do {
                let destination = try await saver.save(item.url, to: directory)
                guard let self else { return }
                savingItems.remove(id)
                defer { onSaveFinished?(nil) }
                guard let current = entries.first(where: { $0.item.id == id }) else { return }
                current.savedDirectory = directory
                current.savedURL = destination
                updateSaveButton(current, directory: settings.saveDirectory)
            } catch {
                guard let self else { return }
                savingItems.remove(id)
                defer { onSaveFinished?(error) }
                guard let current = entries.first(where: { $0.item.id == id }) else { return }
                updateSaveButton(current, directory: settings.saveDirectory)
                guard !isHiddenForCapture, let panel = shelves[current.displayID]?.panel,
                      panel.isVisible, panel.attachedSheet == nil else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The capture couldn’t be saved."
                alert.informativeText = "Couldn’t save to \(directory.path).\n\n\(error.localizedDescription)\n\nYou can change the save folder in Settings."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Settings…")
                alert.beginSheetModal(for: panel) { [weak self] response in
                    if response == .alertSecondButtonReturn { self?.onOpenSettings?() }
                }
            }
        }
    }

    private func updateSaveButton(_ entry: Entry, directory: URL) {
        let isSaving = savingItems.contains(entry.item.id)
        let saved = entry.savedDirectory == directory && entry.savedURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        entry.content.saveButton.title = isSaving ? "Saving…" : (saved ? "Saved" : "Save")
        entry.content.saveButton.isEnabled = !isSaving
        entry.content.saveButton.toolTip = saved ? "Saved to \(entry.savedURL!.path)" : "Save to \(directory.path) (⌘S)"
        entry.content.saveButton.setAccessibilityLabel(entry.content.saveButton.title)
    }

    private func share(_ id: UUID, from button: NSButton) {
        guard let entry = entries.first(where: { $0.item.id == id }) else { return }
        let picker = NSSharingServicePicker(items: [entry.item.url])
        entry.sharePicker = picker
        picker.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
}

@MainActor
private final class CapturePreviewPanel: NSPanel {
    var activeCaptureID: UUID?
    var onMouseDown: ((CGPoint) -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onQuit: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onMouseDown?(event.locationInWindow) }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "q": onQuit?(); return true
        case "c": onCopy?(); return true
        case "s": onSave?(); return true
        case "w": onDismiss?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q": onQuit?(); return
            case "c": onCopy?(); return
            case "s": onSave?(); return
            case "w": onDismiss?(); return
            default: break
            }
        }
        if event.keyCode == 53 { onDismiss?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class PreviewContentView: NSView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onShare: ((NSButton) -> Void)?
    var onClose: (() -> Void)?
    let copyButton = PreviewActionButton(title: "Copy", symbol: "doc.on.doc")
    let saveButton = PreviewActionButton(title: "Save", symbol: "square.and.arrow.down")
    override var isFlipped: Bool { true }

    init(item: CaptureItem) {
        super.init(frame: CGRect(x: 0, y: 0, width: 318, height: 278))
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        let material = NSVisualEffectView(frame: bounds)
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.appearance = NSAppearance(named: .darkAqua)
        addSubview(material)

        let mark = NSImageView(frame: CGRect(x: 13, y: 13, width: 17, height: 17))
        mark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Captured")
        mark.contentTintColor = NSColor(red: 0.39, green: 0.9, blue: 0.77, alpha: 1)
        addSubview(mark)
        let title = label(item.kind == .screenshot ? "SCREENSHOT" : "RECORDING", size: 10, weight: .semibold, color: .white)
        title.frame = CGRect(x: 37, y: 15, width: 220, height: 15)
        title.attributedStringValue = NSAttributedString(string: title.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white,
            .kern: 1.3
        ])
        addSubview(title)
        let close = ClosureButton(frame: CGRect(x: 280, y: 10, width: 25, height: 25))
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss preview")
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Dismiss preview (⌘W)"
        close.setAccessibilityLabel("Dismiss preview")
        close.handler = { [weak self] in self?.onClose?() }
        addSubview(close)

        let thumbnail = DraggableCaptureThumbnail(item: item)
        thumbnail.frame = CGRect(x: 12, y: 42, width: 294, height: 156)
        thumbnail.autoresizingMask = [.width]
        addSubview(thumbnail)

        var metadata = "\(item.kind == .screenshot ? "PNG" : "MP4")  ·  \(Int(item.pixelSize.width)) × \(Int(item.pixelSize.height))"
        if let duration = item.duration {
            let seconds = max(0, Int(duration.rounded()))
            metadata += String(format: "  ·  %d:%02d", seconds / 60, seconds % 60)
        }
        let detail = label(metadata, size: 10, weight: .medium, color: .secondaryLabelColor)
        detail.frame = CGRect(x: 13, y: 207, width: 194, height: 15)
        addSubview(detail)
        let drag = label("Drag to share ↗", size: 10, weight: .regular, color: .tertiaryLabelColor)
        drag.alignment = .right
        drag.frame = CGRect(x: 202, y: 207, width: 103, height: 15)
        addSubview(drag)

        let shareButton = PreviewActionButton(title: "Share", symbol: "square.and.arrow.up")
        let buttons = [copyButton, saveButton, shareButton]
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: 12 + index * 101, y: 232, width: 92, height: 33)
            addSubview(button)
        }
        copyButton.toolTip = "Copy capture (⌘C)"
        saveButton.toolTip = "Save to your default folder (⌘S)"
        shareButton.toolTip = "Open the macOS share menu"
        copyButton.handler = { [weak self] in self?.onCopy?() }
        saveButton.handler = { [weak self] in self?.onSave?() }
        shareButton.handler = { [weak self, weak shareButton] in
            if let shareButton { self?.onShare?(shareButton) }
        }
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { nil }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

@MainActor
private class ClosureButton: NSButton {
    var handler: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(invoke)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler?() }
}

@MainActor
private final class PreviewActionButton: ClosureButton {
    init(title: String, symbol: String) {
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: 11, weight: .medium)
        bezelStyle = .rounded
        isBordered = false
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class DraggableCaptureThumbnail: NSView, NSDraggingSource {
    private let item: CaptureItem
    private var mouseDownPoint: CGPoint?
    private var startedDrag = false
    override var isFlipped: Bool { true }

    init(item: CaptureItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        toolTip = item.kind == .screenshot ? "Click to open. Drag to any app." : "Click to play. Drag to any app."
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(item.kind == .screenshot ? "Screenshot preview. Click to open or drag to share." : "Recording preview. Click to play or drag to share.")
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let size = item.thumbnail.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let target = CGRect(x: (bounds.width - size.width * scale) / 2,
                            y: (bounds.height - size.height * scale) / 2,
                            width: size.width * scale, height: size.height * scale)
        item.thumbnail.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if item.kind == .recording {
            let circle = CGRect(x: bounds.midX - 19, y: bounds.midY - 19, width: 38, height: 38)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: circle).fill()
            if let play = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
                play.withSymbolConfiguration(config)?.draw(in: CGRect(x: bounds.midX - 7, y: bounds.midY - 9, width: 18, height: 18),
                                                          from: .zero, operation: .sourceOver, fraction: 1,
                                                          respectFlipped: true, hints: nil)
            }
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        startedDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !startedDrag, let origin = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
        startedDrag = true
        let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: item.thumbnail)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if !startedDrag, bounds.contains(convert(event.locationInWindow, from: nil)) {
            NSWorkspace.shared.open(item.url)
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
