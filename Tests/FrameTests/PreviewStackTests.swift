import AppKit
import XCTest
@testable import Frame

final class PreviewStackTests: XCTestCase {
    func testNewCapturesRetainEveryIndependentCardInNewestFirstOrder() async throws {
        try await MainActor.run {
            let fixture = try ShelfFixture()
            defer { fixture.cleanup() }
            let first = try fixture.makeItem(1)
            let second = try fixture.makeItem(2, kind: .recording)
            let third = try fixture.makeItem(3)

            [first, second, third].forEach { fixture.controller.show($0) }

            XCTAssertEqual(fixture.controller.captureItems.map(\.id), [third.id, second.id, first.id])
            XCTAssertEqual(fixture.controller.captureItems.map(\.kind), [.screenshot, .recording, .screenshot])
            XCTAssertFalse(fixture.controller.isHiddenForCapture)
            fixture.assertNoWindowsPresented()
        }
    }

    func testDismissingMiddleCardOnlyRemovesThatCardAndPreservesOriginals() async throws {
        try await MainActor.run {
            let fixture = try ShelfFixture()
            defer { fixture.cleanup() }
            let items = try (1...3).map { try fixture.makeItem($0) }
            items.forEach { fixture.controller.show($0) }
            let originals = try items.map { try Data(contentsOf: $0.url) }

            fixture.controller.dismiss(items[1].id)

            XCTAssertEqual(fixture.controller.captureItems.map(\.id), [items[2].id, items[0].id])
            XCTAssertEqual(try items.map { try Data(contentsOf: $0.url) }, originals)
            fixture.controller.dismiss(items[1].id) // An already dismissed ID is harmless.
            XCTAssertEqual(fixture.controller.captureItems.count, 2)
            fixture.assertNoWindowsPresented()
        }
    }

    func testCaptureHideRestoreAndNextCaptureRetainEarlierCards() async throws {
        try await MainActor.run {
            let fixture = try ShelfFixture()
            defer { fixture.cleanup() }
            let first = try fixture.makeItem(1)
            let second = try fixture.makeItem(2)
            let third = try fixture.makeItem(3)
            fixture.controller.show(first)
            fixture.controller.show(second)

            fixture.controller.hideForCapture()
            XCTAssertTrue(fixture.controller.isHiddenForCapture)
            XCTAssertEqual(fixture.controller.captureItems.map(\.id), [second.id, first.id])
            fixture.controller.restoreAfterCapture()
            XCTAssertFalse(fixture.controller.isHiddenForCapture)
            XCTAssertEqual(fixture.controller.captureItems.map(\.id), [second.id, first.id])

            fixture.controller.hideForCapture()
            fixture.controller.show(third)
            XCTAssertFalse(fixture.controller.isHiddenForCapture,
                           "A successful new capture must restore retained cards as well as its new card.")
            XCTAssertEqual(fixture.controller.captureItems.map(\.id), [third.id, second.id, first.id])
            fixture.assertNoWindowsPresented()
        }
    }

    func testOverflowDoesNotDropOlderCardsOrDuplicateAnExistingCapture() async throws {
        try await MainActor.run {
            let fixture = try ShelfFixture()
            defer { fixture.cleanup() }
            let items = try (1...14).map { try fixture.makeItem($0) }
            items.forEach { fixture.controller.show($0) }
            fixture.controller.show(items[0])

            XCTAssertEqual(fixture.controller.captureItems.map(\.id), items.reversed().map(\.id))
            XCTAssertEqual(Set(fixture.controller.captureItems.map(\.id)).count, 14)
            fixture.assertNoWindowsPresented()
        }
    }

    func testSavingOlderAndNewerCardsTargetsTheirOwnFilesIndependently() async throws {
        let saved = expectation(description: "Both independently selected cards finish saving")
        saved.expectedFulfillmentCount = 2
        let fixture = try await MainActor.run { try ShelfFixture() }
        let items = try await MainActor.run { () throws -> [CaptureItem] in
            let items = try [fixture.makeItem(1), fixture.makeItem(2), fixture.makeItem(3, kind: .recording)]
            items.forEach { fixture.controller.show($0) }
            fixture.controller.onSaveFinished = { error in
                XCTAssertNil(error)
                saved.fulfill()
            }
            fixture.controller.save(items[0].id)
            fixture.controller.save(items[2].id)
            XCTAssertTrue(fixture.controller.isSaving)
            return items
        }

        await fulfillment(of: [saved], timeout: 5)
        try await MainActor.run {
            XCTAssertFalse(fixture.controller.isSaving)
            XCTAssertEqual(fixture.controller.captureItems.map(\.id), items.reversed().map(\.id))
            for item in [items[0], items[2]] {
                XCTAssertEqual(try Data(contentsOf: fixture.saveDirectory.appendingPathComponent(item.url.lastPathComponent)),
                               try Data(contentsOf: item.url))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                fixture.saveDirectory.appendingPathComponent(items[1].url.lastPathComponent).path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.saveDirectory.path).count, 2)
        }

        let savedAgain = expectation(description: "Repeated saves complete without duplicating either card")
        savedAgain.expectedFulfillmentCount = 2
        await MainActor.run {
            fixture.controller.onSaveFinished = { error in
                XCTAssertNil(error)
                savedAgain.fulfill()
            }
            fixture.controller.save(items[0].id)
            fixture.controller.save(items[2].id)
        }
        await fulfillment(of: [savedAgain], timeout: 5)
        try await MainActor.run {
            defer { fixture.cleanup() }
            XCTAssertFalse(fixture.controller.isSaving)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.saveDirectory.path).count, 2)
            fixture.assertNoWindowsPresented()
        }
    }

    func testDismissedCardKeepsPendingSaveAliveAndCompletesExactlyOnce() async throws {
        let saved = expectation(description: "Dismissed card's pending save finishes")
        let fixture = try await MainActor.run { try ShelfFixture() }
        let state = await MainActor.run { SaveCompletionState() }
        let item = try await MainActor.run { () throws -> CaptureItem in
            let item = try fixture.makeItem(1)
            let retained = try fixture.makeItem(2)
            fixture.controller.show(item)
            fixture.controller.show(retained)
            fixture.controller.onSaveFinished = { error in
                state.count += 1
                XCTAssertNil(error)
                saved.fulfill()
            }
            fixture.controller.save(item.id)
            XCTAssertTrue(fixture.controller.isSaving)
            fixture.controller.dismiss(item.id)
            XCTAssertTrue(fixture.controller.isSaving, "Quit must keep waiting after the saving card is dismissed.")
            XCTAssertEqual(fixture.controller.captureItems.map(\.id), [retained.id])
            return item
        }

        await fulfillment(of: [saved], timeout: 5)
        try await MainActor.run {
            defer { fixture.cleanup() }
            XCTAssertEqual(state.count, 1)
            XCTAssertFalse(fixture.controller.isSaving)
            XCTAssertEqual(fixture.controller.captureItems.count, 1)
            XCTAssertEqual(try Data(contentsOf: fixture.saveDirectory.appendingPathComponent(item.url.lastPathComponent)),
                           try Data(contentsOf: item.url))
            fixture.assertNoWindowsPresented()
        }
    }
}

@MainActor
private final class SaveCompletionState {
    var count = 0
}

@MainActor
private final class ShelfFixture {
    let directory: URL
    let saveDirectory: URL
    let controller: PreviewController
    private let suiteName: String
    private let defaults: UserDefaults
    private let existingWindows: Set<Int>

    init() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        existingWindows = Set(application.windows.map(\.windowNumber))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Frame-PreviewStackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        saveDirectory = directory.appendingPathComponent("Saved", isDirectory: true)
        suiteName = "Frame.PreviewStackTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = CaptureSettings(defaults: defaults)
        settings.setSaveDirectory(saveDirectory)
        controller = PreviewController(settings: settings, presentsWindows: false)
    }

    func makeItem(_ number: Int, kind: CaptureKind = .screenshot) throws -> CaptureItem {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 12,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let color = NSColor(calibratedHue: CGFloat(number % 17) / 17, saturation: 0.6, brightness: 0.8, alpha: 1)
        for x in 0..<16 {
            for y in 0..<12 { bitmap.setColor(color, atX: x, y: y) }
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let thumbnail = NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: CGSize(width: 16, height: 12))
        let url = directory.appendingPathComponent("Capture-\(number).\(kind == .screenshot ? "png" : "mp4")")
        let data = kind == .screenshot ? png : Data("Synthetic recording fixture \(number)".utf8)
        try data.write(to: url)
        return CaptureItem(kind: kind, url: url, thumbnail: thumbnail, pixelSize: CGSize(width: 16, height: 12),
                           duration: kind == .recording ? 2 : nil)
    }

    func assertNoWindowsPresented(file: StaticString = #filePath, line: UInt = #line) {
        let newWindows = NSApplication.shared.windows.filter { !existingWindows.contains($0.windowNumber) }
        XCTAssertFalse(newWindows.contains(where: \.isVisible), "Test preview shelves must remain offscreen.",
                       file: file, line: line)
    }

    func cleanup() {
        controller.onSaveFinished = nil
        controller.captureItems.forEach { controller.dismiss($0.id) }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
