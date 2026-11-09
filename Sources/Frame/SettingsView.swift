import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: CaptureSettings
    private let mint = Color(red: 0.43, green: 0.91, blue: 0.77)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(mint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Save location").font(.system(size: 21, weight: .semibold))
                        Text("One click. Right where you want it.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("DEFAULT FOLDER").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(mint).font(.system(size: 17))
                        Text(settings.saveDirectory.path)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Default save folder: \(settings.saveDirectory.path)")
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.08)))

                HStack(spacing: 10) {
                    Button("Change Folder…", action: chooseFolder)
                        .buttonStyle(.borderedProminent).tint(mint)
                    Button("Show in Finder") { NSWorkspace.shared.open(settings.saveDirectory) }
                        .buttonStyle(.bordered)
                        .disabled(!FileManager.default.fileExists(atPath: settings.saveDirectory.path))
                    Spacer(minLength: 0)
                }.controlSize(.regular)

                Text("Save writes screenshots and recordings directly to this folder. Changes are saved automatically.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(24)
        }
        .frame(width: 540, height: 280)
        .background(LinearGradient(colors: [Color(red: 0.075, green: 0.09, blue: 0.105),
                                           Color(red: 0.045, green: 0.052, blue: 0.064)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.dark)
    }

    private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = "Select Frame save folder"
        picker.message = "Screenshots and recordings save here when you click Save."
        picker.prompt = "Choose Folder"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.directoryURL = settings.saveDirectory
        let onComplete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let directory = picker.url else { return }
            settings.setSaveDirectory(directory)
        }
        if let window = NSApp.keyWindow {
            picker.beginSheetModal(for: window, completionHandler: onComplete)
        } else {
            picker.begin(completionHandler: onComplete)
        }
    }
}
