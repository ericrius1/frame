import AppKit
import XCTest
@testable import Frame

final class CaptureThumbnailTests: XCTestCase {
    func testLandscapePreviewIsDownsampledTo960By480() throws {
        let original = try makeImage(width: 2400, height: 1200)
        let thumbnail = CaptureThumbnail.image(from: original)
        let bitmap = try bitmap(from: thumbnail)
        XCTAssertEqual(bitmap.width, 960)
        XCTAssertEqual(bitmap.height, 480)
        XCTAssertEqual(thumbnail.size, CGSize(width: 960, height: 480))
    }

    func testPortraitPreviewIsDownsampledTo480By960() throws {
        let original = try makeImage(width: 1200, height: 2400)
        let thumbnail = try bitmap(from: CaptureThumbnail.image(from: original))
        XCTAssertEqual(thumbnail.width, 480)
        XCTAssertEqual(thumbnail.height, 960)
    }

    func testSmallCaptureIsNotUpscaled() throws {
        let original = try makeImage(width: 160, height: 100)
        let thumbnail = try bitmap(from: CaptureThumbnail.image(from: original))
        XCTAssertEqual(thumbnail.width, 160)
        XCTAssertEqual(thumbnail.height, 100)
    }

    func testVeryThinCapturesAndInvalidLimitsKeepAtLeastOnePixel() throws {
        let tall = try makeImage(width: 1, height: 2400)
        let wide = try makeImage(width: 2400, height: 1)
        let tallPreview = try bitmap(from: CaptureThumbnail.image(from: tall))
        let widePreview = try bitmap(from: CaptureThumbnail.image(from: wide))
        XCTAssertEqual(tallPreview.width, 1)
        XCTAssertEqual(tallPreview.height, 960)
        XCTAssertEqual(widePreview.width, 960)
        XCTAssertEqual(widePreview.height, 1)
        for limit in [0, -10] {
            let minimum = try bitmap(from: CaptureThumbnail.image(from: tall, maxDimension: limit))
            XCTAssertEqual(minimum.width, 1)
            XCTAssertEqual(minimum.height, 1)
        }
        let singlePixel = try makeImage(width: 1, height: 1)
        let singlePreview = try bitmap(from: CaptureThumbnail.image(from: singlePixel))
        XCTAssertEqual(singlePreview.width, 1)
        XCTAssertEqual(singlePreview.height, 1)
    }

    func testOriginalResolutionAndPixelsStayUnchanged() throws {
        let original = try makeImage(width: 2400, height: 1200)
        let originalBytes = try XCTUnwrap(original.dataProvider?.data) as Data
        _ = CaptureThumbnail.image(from: original)
        XCTAssertEqual(original.width, 2400)
        XCTAssertEqual(original.height, 1200)
        XCTAssertEqual(try XCTUnwrap(original.dataProvider?.data) as Data, originalBytes)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func bitmap(from image: NSImage) throws -> CGImage {
        try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
}
