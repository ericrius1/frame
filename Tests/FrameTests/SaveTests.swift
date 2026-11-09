import XCTest
@testable import Frame

final class SaveTests: XCTestCase {
    func testDefaultSaveFolderAndChangedFolderPersistWithoutCreatingDirectories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await MainActor.run {
            let suite = "Frame.SaveTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = CaptureSettings(defaults: defaults)
            XCTAssertEqual(settings.saveDirectory.path, CaptureSettings.defaultSaveDirectory.path)
            XCTAssertTrue(settings.saveDirectory.path.hasSuffix("/Pictures/Frame"))

            let chosen = root.appendingPathComponent("Unused/../My Captures", isDirectory: true)
            settings.setSaveDirectory(chosen)
            XCTAssertEqual(settings.saveDirectory.path, chosen.standardizedFileURL.path)
            XCTAssertEqual(CaptureSettings(defaults: defaults).saveDirectory.path,
                           chosen.standardizedFileURL.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: settings.saveDirectory.path),
                           "Choosing a folder must not create it before a capture is saved.")
        }
    }

    func testSaveCreatesNestedFolderAndPreservesOriginalBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<8192).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("Frame Screenshot.png")
        try payload.write(to: source)
        let folder = root.appendingPathComponent("New/Nested Captures", isDirectory: true)

        let saved = try await CaptureSaver().save(source, to: folder)

        XCTAssertEqual(saved, folder.appendingPathComponent(source.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: saved), payload)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertEqual(try filenames(in: folder), [source.lastPathComponent])
    }

    func testExistingFilesArePreservedAndCollisionSuffixKeepsExtension() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Frame Recording.mp4")
        let payload = Data("new recording fixture".utf8)
        let existing = Data("keep this existing recording".utf8)
        let secondExisting = Data("keep the first duplicate too".utf8)
        try payload.write(to: source)
        let occupied = folder.appendingPathComponent(source.lastPathComponent)
        let occupiedSecond = folder.appendingPathComponent("Frame Recording (2).mp4")
        try existing.write(to: occupied)
        try secondExisting.write(to: occupiedSecond)

        let saved = try await CaptureSaver().save(source, to: folder)

        XCTAssertEqual(saved.lastPathComponent, "Frame Recording (3).mp4")
        XCTAssertEqual(saved.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: saved), payload)
        XCTAssertEqual(try Data(contentsOf: occupied), existing)
        XCTAssertEqual(try Data(contentsOf: occupiedSecond), secondExisting)
        XCTAssertFalse(try filenames(in: folder).contains { $0.hasSuffix(".partial") })
    }

    func testRepeatedAndConcurrentSaveClicksDoNotCreateDuplicates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Capture.png")
        try Data("image fixture".utf8).write(to: source)
        let folder = root.appendingPathComponent("Saved", isDirectory: true)
        let saver = CaptureSaver()

        async let first = saver.save(source, to: folder)
        async let simultaneous = saver.save(source, to: folder)
        let destinations = try await (first, simultaneous)
        let repeated = try await saver.save(source, to: folder)

        XCTAssertEqual(destinations.0, destinations.1)
        XCTAssertEqual(repeated, destinations.0)
        XCTAssertEqual(try filenames(in: folder), [source.lastPathComponent])
    }

    func testSameCaptureCanBeSavedAgainAfterChangingFolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Capture.png")
        let payload = Data("image fixture".utf8)
        try payload.write(to: source)
        let saver = CaptureSaver()
        let firstFolder = root.appendingPathComponent("First", isDirectory: true)
        let secondFolder = root.appendingPathComponent("Second", isDirectory: true)

        let first = try await saver.save(source, to: firstFolder)
        let second = try await saver.save(source, to: secondFolder)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent(), firstFolder)
        XCTAssertEqual(second.deletingLastPathComponent(), secondFolder)
        XCTAssertEqual(try Data(contentsOf: first), payload)
        XCTAssertEqual(try Data(contentsOf: second), payload)
    }

    func testCaptureAlreadyInDestinationReturnsOriginalWithoutDuplicate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Capture.png")
        let payload = Data("image fixture".utf8)
        try payload.write(to: source)

        let saved = try await CaptureSaver().save(source, to: root)

        XCTAssertEqual(saved, source)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertEqual(try filenames(in: root), [source.lastPathComponent])
    }

    func testDirectoryThatIsAFileFailsWithoutChangingExistingData() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Capture.png")
        let invalidDirectory = root.appendingPathComponent("Not A Folder")
        let existing = Data("keep existing file".utf8)
        try Data("image fixture".utf8).write(to: source)
        try existing.write(to: invalidDirectory)

        do {
            _ = try await CaptureSaver().save(source, to: invalidDirectory)
            XCTFail("Saving into a regular file must fail.")
        } catch {
            XCTAssertEqual(try Data(contentsOf: invalidDirectory), existing)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertFalse(try filenames(in: root).contains { $0.hasSuffix(".partial") })
        }
    }

    func testMissingSourceFailsAndLeavesNoPartialFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Missing Capture.png")
        let folder = root.appendingPathComponent("Saved", isDirectory: true)

        do {
            _ = try await CaptureSaver().save(source, to: folder)
            XCTFail("Saving a missing capture must fail.")
        } catch {
            XCTAssertEqual(try filenames(in: folder), [])
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Frame-SaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func filenames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
