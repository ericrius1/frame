import SwiftUI

private let frameMint = Color(red: 0.43, green: 0.91, blue: 0.77)

struct DashboardView: View {
    @ObservedObject var app: AppCoordinator
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(frameMint.opacity(0.12))
                    Image(systemName: "viewfinder").font(.system(size: 27, weight: .medium)).foregroundStyle(frameMint)
                }.frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Frame").font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("A little room for what matters.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(app.isRecording ? Color.red : frameMint).frame(width: 6, height: 6)
                    Text(app.isRecording ? app.elapsedText : "IN YOUR MENU BAR")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                }.foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                captureCard(title: "Take a screenshot", detail: "Drag. Capture. Share.",
                            symbol: "crop", shortcut: "⌘ ⇧ 4", tint: frameMint) { app.beginCapture(.screenshot) }
                captureCard(title: app.isRecording ? "Stop recording" : "Record your screen",
                            detail: app.isRecording ? "Finish and open your preview." : "A moment, in motion.",
                            symbol: app.isRecording ? "stop.circle" : "record.circle",
                            shortcut: "⌘ ⇧ R", tint: Color(red: 1, green: 0.56, blue: 0.45)) { app.toggleRecording() }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("RECORDING AUDIO").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                    Spacer()
                    Text("Choose what comes along").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    ForEach(AudioMode.allCases) { mode in
                        Button { app.audioMode = mode } label: {
                            VStack(spacing: 8) {
                                Image(systemName: mode.symbol).font(.system(size: 17, weight: .medium)).frame(height: 21)
                                Text(mode == .both ? "Both" : mode.title).font(.system(size: 11, weight: .medium))
                            }.frame(maxWidth: .infinity).frame(height: 65)
                                .foregroundStyle(app.audioMode == mode ? frameMint : Color.white.opacity(0.55))
                                .background(app.audioMode == mode ? frameMint.opacity(0.10) : Color.white.opacity(0.025))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(app.audioMode == mode ? frameMint.opacity(0.55) : Color.white.opacity(0.07)))
                        }.buttonStyle(.plain).disabled(app.isRecording || app.isStarting || app.isFinalizing)
                            .accessibilityLabel(mode.title).accessibilityAddTraits(app.audioMode == mode ? .isSelected : [])
                    }
                }
                Text(app.audioMode.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                statusRow(symbol: app.screenPermission ? "checkmark.shield" : "lock.open",
                          title: app.isCheckingScreenAccess ? "Checking screen access…" : (app.screenPermission ? "Screen capture is ready" : "Allow screen capture"),
                          detail: app.screenPermission ? "Screenshots and recordings stay on your Mac." : "Allow Frame in Screen & System Audio Recording, then relaunch if macOS asks.",
                          ready: app.screenPermission,
                          actionTitle: app.screenPermission ? nil : "Recheck", action: app.requestScreenPermission)
                if !app.screenPermission {
                    HStack(spacing: 12) {
                        Button("Open System Settings", action: app.openPrivacySettings)
                        Button("Relaunch Frame", action: app.relaunch)
                    }.controlSize(.small).padding(.leading, 29).disabled(app.busy || app.isSavingCapture)
                }
                if !app.screenshotShortcutReady || !app.recordingShortcutReady {
                    Divider().overlay(Color.white.opacity(0.05))
                    statusRow(symbol: "keyboard", title: "Make room for your shortcuts",
                              detail: "In Keyboard Shortcuts → Screenshots, turn off ⌘⇧4. Quit any other app using these shortcuts, then retry.",
                              ready: false, actionTitle: "Set up", action: app.openKeyboardSettings)
                    Button("Recheck shortcuts", action: app.refreshShortcuts)
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(frameMint)
                        .padding(.leading, 29)
                }
                if let notice = app.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(15).background(Color.white.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 30).padding(.top, 42).padding(.bottom, 12)
        .frame(width: 650)
        .background(LinearGradient(colors: [Color(red: 0.075, green: 0.09, blue: 0.105), Color(red: 0.045, green: 0.052, blue: 0.064)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.dark)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "rectangle.bottomthird.inset.filled").font(.system(size: 11))
                Text("Captures appear in the bottom-left corner.")
                Spacer()
                Button(action: app.showSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityLabel("Open Frame settings")
                Button("Quit Frame", action: app.requestQuit)
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Quit Frame (⌘Q)").accessibilityLabel("Quit Frame")
            }.font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 30).padding(.vertical, 15)
                .background(Color(red: 0.045, green: 0.052, blue: 0.064))
                .overlay(alignment: .top) { Color.white.opacity(0.06).frame(height: 1) }
        }
        .frame(width: 650, height: 600)
        .background(Color(red: 0.045, green: 0.052, blue: 0.064))
        .preferredColorScheme(.dark)
    }

    private func captureCard(title: String, detail: String, symbol: String, shortcut: String, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(tint)
                    Spacer()
                    Text(shortcut).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 5))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(19).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
        }.buttonStyle(.plain)
            .disabled(app.busy && !(symbol == "stop.circle" && app.isRecording))
    }

    private func statusRow(symbol: String, title: String, detail: String, ready: Bool,
                           actionTitle: String?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(ready ? frameMint : Color.orange).frame(width: 17)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
    }
}

struct RecordingControls: View {
    @ObservedObject var app: AppCoordinator
    var body: some View {
        HStack(spacing: 16) {
            if app.isRecording || app.isFinalizing {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(app.isFinalizing ? "Finishing…" : app.elapsedText)
                    .font(.system(size: 18, weight: .medium, design: .monospaced)).monospacedDigit()
                Spacer(minLength: 2)
                Button(action: app.stopRecording) {
                    Label("Stop", systemImage: "stop.fill").font(.system(size: 12)).frame(minWidth: 52, minHeight: 32)
                }.buttonStyle(.borderedProminent).tint(.red).disabled(app.isFinalizing)
                    .help("Stop recording (⌘⇧R)").accessibilityLabel("Stop recording")
            } else {
                Button(action: app.cancelSelectedRecording) {
                    HStack(spacing: 5) {
                        Label("Cancel", systemImage: "xmark")
                        Text("esc").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    }.font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction).disabled(app.isStarting)
                    .help("Cancel recording setup (Esc)").accessibilityLabel("Cancel recording setup")
                Menu {
                    ForEach(AudioMode.allCases) { mode in
                        Button { app.audioMode = mode } label: {
                            Label(mode.title + (app.audioMode == mode ? " ✓" : ""), systemImage: mode.symbol)
                        }
                    }
                } label: {
                    Label(app.audioMode.title, systemImage: app.audioMode.symbol).font(.system(size: 12))
                }.menuStyle(.borderlessButton).frame(maxWidth: .infinity).disabled(app.isStarting)
                Button(action: app.startSelectedRecording) {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                        Text(app.isStarting ? "Starting…" : "Record")
                    }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).tint(.red).keyboardShortcut(.defaultAction).disabled(app.isStarting)
            }
        }.padding(.horizontal, 20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.white.opacity(0.13)))
            .padding(4).preferredColorScheme(.dark)
    }
}
