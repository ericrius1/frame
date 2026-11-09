import Foundation

/// Copies on an actor executor so a large recording never blocks the capture UI.
actor CaptureSaver {
    private struct SaveKey: Hashable {
        let source: URL
        let directory: URL
    }
    private var savedFiles: [SaveKey: URL] = [:]

    func save(_ source: URL, to directory: URL) throws -> URL {
        let source = source.standardizedFileURL
        let directory = directory.standardizedFileURL
        let fileManager = FileManager.default
        let key = SaveKey(source: source, directory: directory)
        if let saved = savedFiles[key], fileManager.fileExists(atPath: saved.path) { return saved }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if source == destination {
            guard fileManager.fileExists(atPath: source.path) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            savedFiles[key] = source
            return source
        }

        // Stage once, then move without replacing any existing file. The final PNG/MP4
        // appears only when its entire copy is ready, including on a different volume.
        let staged = directory.appendingPathComponent(".Frame-save-\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: source, to: staged)
        var suffix = 1
        while true {
            let candidate: URL
            if suffix == 1 {
                candidate = destination
            } else {
                let stem = destination.deletingPathExtension().lastPathComponent
                let name = "\(stem) (\(suffix))"
                let url = directory.appendingPathComponent(name)
                candidate = destination.pathExtension.isEmpty ? url : url.appendingPathExtension(destination.pathExtension)
            }
            do {
                try fileManager.moveItem(at: staged, to: candidate)
                savedFiles[key] = candidate
                return candidate
            } catch {
                guard fileManager.fileExists(atPath: candidate.path) else { throw error }
                suffix += 1
            }
        }
    }
}
