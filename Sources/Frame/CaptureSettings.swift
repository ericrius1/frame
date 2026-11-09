import Foundation
import Combine

@MainActor
final class CaptureSettings: ObservableObject {
    static let shared = CaptureSettings()
    static let defaultSaveDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Frame", isDirectory: true)

    @Published private(set) var saveDirectory: URL
    private let defaults: UserDefaults
    private static let saveDirectoryKey = "saveDirectoryPath"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: Self.saveDirectoryKey), !path.isEmpty, path.hasPrefix("/") {
            saveDirectory = Self.normalizedDirectory(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            saveDirectory = Self.defaultSaveDirectory
        }
    }

    func setSaveDirectory(_ url: URL) {
        guard url.isFileURL else { return }
        let directory = Self.normalizedDirectory(url)
        saveDirectory = directory
        defaults.set(directory.path, forKey: Self.saveDirectoryKey)
    }

    private static func normalizedDirectory(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }
}
