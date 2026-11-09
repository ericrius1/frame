import AppKit
import SwiftUI
import AVFoundation

@MainActor
final class AppCoordinator: NSObject, ObservableObject, NSMenuDelegate {
    @Published var audioMode: AudioMode = AudioMode(rawValue: UserDefaults.standard.string(forKey: "audioMode") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(audioMode.rawValue, forKey: "audioMode") }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var isStarting = false
    @Published private(set) var isSelecting = false
    @Published private(set) var isCheckingScreenAccess = false
    @Published private(set) var isRelaunching = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var screenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var screenshotShortcutReady = false
    @Published private(set) var recordingShortcutReady = false
    @Published var notice: String?
    private let engine = CaptureEngine()
    private let selection = SelectionController()
    private let previews = PreviewController()
    private let hotkeys = HotkeyManager()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var recordingPanel: NSPanel?
    private var outline: NSWindow?
    private var selectedRegion: CaptureRegion?
    private var hiddenMainWindow = false
    private var hiddenSettingsWindow = false
    private var startedAt: Date?
    private var timer: Timer?
    private var quitAfterStop = false
    private var activationObserver: NSObjectProtocol?
    private var confirmedScreenAccess: Bool?

    var busy: Bool { isRelaunching || isCheckingScreenAccess || isSelecting || isStarting || isRecording || isFinalizing || selectedRegion != nil }
    var isStartingRecording: Bool { isStarting && selectedRegion != nil }
    var isSavingCapture: Bool { previews.isSaving }
    var elapsedText: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func launch() {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        hotkeys.onScreenshot = { [weak self] in self?.beginCapture(.screenshot) }
        hotkeys.onRecording = { [weak self] in self?.toggleRecording() }
        engine.onUnexpectedStop = { [weak self] error in self?.recordingFailed(error) }
        selection.onQuitRequested = { [weak self] in self?.requestQuit() }
        previews.onQuitRequested = { [weak self] in self?.requestQuit() }
        previews.onOpenSettings = { [weak self] in self?.showSettings() }
        previews.onSaveFinished = { [weak self] error in
            guard let self else { return }
            if let error {
                self.notice = "The capture couldn’t be saved. \(error.localizedDescription)"
                if self.quitAfterStop {
                    self.quitAfterStop = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                    self.showWindow()
                }
            } else {
                self.finishPendingQuitIfReady()
            }
        }
        refreshShortcuts()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        showWindow()
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Frame", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Frame")
        appMenu.addItem(withTitle: "About Frame", action: #selector(showAbout), keyEquivalent: "") .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Frame", action: #selector(quitFromMenu), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    func refreshPermissions() {
        screenPermission = confirmedScreenAccess ?? CGPreflightScreenCaptureAccess()
        screenshotShortcutReady = hotkeys.screenshotAvailable && !hotkeys.systemScreenshotShortcutEnabled
        recordingShortcutReady = hotkeys.recordingAvailable
    }

    func refreshShortcuts() {
        guard !isRelaunching else { return }
        hotkeys.register()
        refreshPermissions()
    }

    func requestScreenPermission() {
        guard !busy else { return }
        verifyScreenAccess(then: nil)
    }

    private func verifyScreenAccess(then kind: CaptureKind?) {
        guard !isCheckingScreenAccess else { return }
        isCheckingScreenAccess = true
        notice = nil
        Task { @MainActor in
            do {
                // ScreenCaptureKit is the authority for the API we actually use.
                // Quartz's preflight result is only an initial dashboard hint.
                try await engine.checkScreenAccess()
                confirmedScreenAccess = true
                screenPermission = true
                isCheckingScreenAccess = false
                if let kind { selectCaptureArea(kind) }
            } catch {
                isCheckingScreenAccess = false
                presentCaptureError(error)
            }
        }
    }

    private func presentCaptureError(_ error: Error) {
        if CaptureEngine.isScreenPermissionError(error) {
            confirmedScreenAccess = false
            screenPermission = false
            notice = "macOS hasn’t accepted screen access for this running copy of Frame. If Frame is already enabled in Settings, relaunch it, then recheck access."
            showWindow()
        } else {
            presentError(error)
        }
    }

    func relaunch() {
        guard !busy, !isSavingCapture else {
            notice = "Finish the current capture or save before relaunching Frame."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        isRelaunching = true
        hotkeys.unregister()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.isRelaunching = false
                    self.refreshShortcuts()
                    self.presentError(error)
                } else {
                    self.requestQuit()
                }
            }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")!)
    }

    func showWindow() {
        if window == nil {
            let panel = FrameWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 600),
                                 styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
            panel.title = "Frame"
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.08, alpha: 1)
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = NSHostingView(rootView: DashboardView(app: self))
            panel.onQuit = { [weak self] in self?.requestQuit() }
            panel.onEscape = { [weak panel] in panel?.performClose(nil) }
            panel.center()
            window = panel
        }
        refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func beginCapture(_ kind: CaptureKind) {
        guard !busy else { NSSound.beep(); return }
        verifyScreenAccess(then: kind)
    }

    private func selectCaptureArea(_ kind: CaptureKind) {
        notice = nil
        (settingsWindow?.attachedSheet as? NSOpenPanel)?.cancel(nil)
        hiddenMainWindow = window?.isVisible ?? false
        hiddenSettingsWindow = settingsWindow?.isVisible ?? false
        window?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        previews.hideForCapture()
        isSelecting = true
        selection.select(kind: kind) { [weak self] region in
            guard let self else { return }
            self.isSelecting = false
            guard let region else { self.restoreAfterCancel(); return }
            if kind == .recording {
                self.selectedRegion = region
                self.showRecordingControls(region: region)
            } else {
                self.isStarting = true
                Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(140))
                        let item = try await self.engine.screenshot(region: region)
                        self.isStarting = false
                        self.previews.show(item, on: region.screen)
                        self.hiddenMainWindow = false
                        self.hiddenSettingsWindow = false
                    } catch {
                        self.isStarting = false
                        self.restoreAfterCancel()
                        self.presentCaptureError(error)
                    }
                }
            }
        }
    }

    func toggleRecording() {
        guard !isFinalizing else { return }
        if isRecording { stopRecording() }
        else if selectedRegion != nil && !isStarting { startSelectedRecording() }
        else if !busy { beginCapture(.recording) }
    }

    func startSelectedRecording() {
        guard let region = selectedRegion, !isStarting, !isRecording, !isFinalizing else { return }
        isStarting = true
        let audio = audioMode
        Task { @MainActor in
            if audio.includesMicrophone {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else {
                    self.isStarting = false
                    if self.quitAfterStop {
                        self.cancelSelectedRecording()
                        self.finishPendingQuitIfReady()
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = "Microphone access is needed"
                    alert.informativeText = "Allow Frame in System Settings → Privacy & Security → Microphone, or choose None or System audio."
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Keep choosing")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    return
                }
            }
            do {
                try await engine.startRecording(region: region, audio: audio)
                isStarting = false
                isRecording = true
                startedAt = Date()
                elapsed = 0
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let startedAt = self.startedAt else { return }
                        self.elapsed = Date().timeIntervalSince(startedAt)
                        self.updateStatusItem()
                    }
                }
                updateStatusItem()
                resizeRecordingPanel(region: region)
                if quitAfterStop { stopRecording() }
            } catch {
                isStarting = false
                cancelSelectedRecording()
                cancelPendingQuit()
                presentCaptureError(error)
            }
        }
    }

    func stopRecording() {
        guard isRecording, !isFinalizing else { return }
        isRecording = false
        isFinalizing = true
        timer?.invalidate()
        timer = nil
        outline?.orderOut(nil)
        updateStatusItem()
        let screen = selectedRegion?.screen
        Task { @MainActor in
            do {
                let item = try await engine.stopRecording()
                resetRecordingUI()
                previews.show(item, on: screen)
                finishPendingQuitIfReady()
            } catch {
                resetRecordingUI()
                previews.restoreAfterCapture()
                cancelPendingQuit()
                presentCaptureError(error)
            }
        }
    }

    func stopAndQuit() {
        quitAfterStop = true
        if isRecording { stopRecording() }
        else { finishPendingQuitIfReady() }
    }

    func requestQuit() {
        NSApp.terminate(nil)
    }

    func cancelCaptureSetup() {
        if isSelecting { selection.cancel() }
        if selectedRegion != nil && !isStarting && !isRecording && !isFinalizing { cancelSelectedRecording() }
    }

    private func cancelPendingQuit() {
        guard quitAfterStop else { return }
        quitAfterStop = false
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    private func finishPendingQuitIfReady() {
        guard quitAfterStop, !isRecording, !isFinalizing, !isStartingRecording, !previews.isSaving else { return }
        quitAfterStop = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func recordingFailed(_ error: Error) {
        resetRecordingUI()
        previews.restoreAfterCapture()
        cancelPendingQuit()
        presentCaptureError(error)
    }

    private func resetRecordingUI() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        isRecording = false
        isFinalizing = false
        isStarting = false
        selectedRegion = nil
        recordingPanel?.close()
        recordingPanel = nil
        outline?.close()
        outline = nil
        hiddenMainWindow = false
        hiddenSettingsWindow = false
        updateStatusItem()
    }

    func cancelSelectedRecording() {
        guard !isStarting, !isRecording, !isFinalizing else { return }
        selectedRegion = nil
        recordingPanel?.close()
        recordingPanel = nil
        outline?.close()
        outline = nil
        restoreAfterCancel()
    }

    private func restoreAfterCancel() {
        previews.restoreAfterCapture()
        if hiddenMainWindow { window?.makeKeyAndOrderFront(nil) }
        if hiddenSettingsWindow { settingsWindow?.makeKeyAndOrderFront(nil) }
        hiddenMainWindow = false
        hiddenSettingsWindow = false
    }

    func showSettings() {
        guard !isSelecting else { return }
        if settingsWindow == nil {
            let panel = FrameWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 280),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Frame Settings"
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.08, alpha: 1)
            panel.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
            panel.onQuit = { [weak self] in self?.requestQuit() }
            panel.onEscape = { [weak panel] in panel?.performClose(nil) }
            panel.center()
            settingsWindow = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showRecordingControls(region: CaptureRegion) {
        // Non-activating panels, like the selection overlay, so the outline and controls
        // also appear over a full-screen app.
        let border = NSPanel(contentRect: region.globalRect.insetBy(dx: -3, dy: -3),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.hidesOnDeactivate = false
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.isReleasedWhenClosed = false
        border.ignoresMouseEvents = true
        border.level = .floating
        border.sharingType = .none
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.contentView = NSHostingView(rootView: RoundedRectangle(cornerRadius: 3)
            .stroke(Color.mint.opacity(0.9), lineWidth: 2).padding(1))
        border.orderFrontRegardless()
        outline = border

        let panel = ControlPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 78),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.sharingType = .none
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingControls(app: self))
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onQuit = { [weak self] in self?.requestQuit() }
        panel.onEscape = { [weak self] in self?.cancelSelectedRecording() }
        recordingPanel = panel
        resizeRecordingPanel(region: region)
        panel.makeKeyAndOrderFront(nil)
    }

    private func resizeRecordingPanel(region: CaptureRegion) {
        guard let panel = recordingPanel else { return }
        let width: CGFloat = isRecording ? 272 : 430
        let height: CGFloat = 78
        let visible = region.screen.visibleFrame.insetBy(dx: 14, dy: 14)
        let desiredY = region.globalRect.minY - height - 14
        let y = desiredY >= visible.minY ? desiredY : min(region.globalRect.maxY + 14, visible.maxY - height)
        let x = min(max(region.globalRect.midX - width / 2, visible.minX), visible.maxX - width)
        panel.setFrame(NSRect(x: x, y: max(visible.minY, y), width: width, height: height), display: true)
    }

    private func presentError(_ error: Error) {
        notice = error.localizedDescription
        showWindow()
        let alert = NSAlert(error: error)
        alert.messageText = "Frame couldn’t finish that capture"
        alert.runModal()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol = isRecording ? "record.circle.fill" : "viewfinder"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Frame")
        button.contentTintColor = isRecording ? .systemRed : nil
        button.title = isRecording ? "  \(elapsedText)" : (isFinalizing ? "  Saving…" : "")
        button.toolTip = isRecording ? "Frame — recording. ⌘⇧R to stop." : "Frame — screenshots & recordings"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        add("Capture area                         ⌘⇧4", #selector(captureFromMenu), enabled: !busy)
        add(isRecording ? "Stop recording                       ⌘⇧R" : "Record area                           ⌘⇧R",
            #selector(recordFromMenu), enabled: !busy || isRecording)
        let audioItem = NSMenuItem(title: "Recording audio", action: nil, keyEquivalent: "")
        let audioMenu = NSMenu()
        for mode in AudioMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setAudioFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = audioMode == mode ? .on : .off
            item.isEnabled = !isRecording && !isStarting && !isFinalizing
            audioMenu.addItem(item)
        }
        audioItem.submenu = audioMenu
        menu.addItem(audioItem)
        menu.addItem(.separator())
        add("Open Frame…", #selector(openFromMenu))
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        add("Quit Frame", #selector(quitFromMenu))
    }

    @objc private func captureFromMenu() { beginCapture(.screenshot) }
    @objc private func recordFromMenu() { toggleRecording() }
    @objc private func openFromMenu() { showWindow() }
    @objc private func settingsFromMenu() { showSettings() }
    @objc private func quitFromMenu() { requestQuit() }
    @objc private func setAudioFromMenu(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String, let mode = AudioMode(rawValue: value) { audioMode = mode }
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Frame", .applicationVersion: "0.6.1",
            .credits: NSAttributedString(string: "A little room for what matters.\nArea screenshots and recordings, made for your Mac.")])
    }
}

private final class ControlPanel: NSPanel {
    var onQuit: (() -> Void)?
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "q" {
            onQuit?()
            return true
        }
        if event.keyCode == 53, modifiers.isEmpty {
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
