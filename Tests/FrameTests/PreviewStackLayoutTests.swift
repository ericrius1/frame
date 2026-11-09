import XCTest
import CoreGraphics
@testable import Frame

final class PreviewStackLayoutTests: XCTestCase {
    func testEmptyAndNegativeCountsHaveNoCardsOrDocumentHeight() {
        for count in [0, -1, -20] {
            XCTAssertEqual(PreviewStackLayout.documentHeight(count: count), 0)
            XCTAssertEqual(PreviewStackLayout.cardFrames(count: count), [])
            XCTAssertEqual(PreviewStackLayout.panelFrame(visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                        count: count).height, 0)
        }
    }

    func testOneCaptureStartsAtBottomWithExactCardSize() {
        XCTAssertEqual(PreviewStackLayout.cardFrames(count: 1),
                       [CGRect(x: 0, y: 0, width: 318, height: 278)])
        XCTAssertEqual(PreviewStackLayout.documentHeight(count: 1), 278)
    }

    func testTwoCapturesPlaceOlderAboveNewestWithTwelvePointGap() {
        let frames = PreviewStackLayout.cardFrames(count: 2)
        XCTAssertEqual(frames, [CGRect(x: 0, y: 0, width: 318, height: 278),
                                CGRect(x: 0, y: 290, width: 318, height: 278)])
        XCTAssertEqual(frames[1].minY - frames[0].maxY, 12)
        XCTAssertEqual(PreviewStackLayout.documentHeight(count: 2), 568)
    }

    func testTenCapturesRetainTheirOrderAndDoNotOverlap() throws {
        let frames = PreviewStackLayout.cardFrames(count: 10)
        XCTAssertEqual(frames.count, 10)
        XCTAssertEqual(PreviewStackLayout.documentHeight(count: 10), 2888)
        XCTAssertEqual(try XCTUnwrap(frames.first).minY, 0)
        XCTAssertEqual(try XCTUnwrap(frames.last).maxY, 2888)
        for index in frames.indices {
            XCTAssertEqual(frames[index].size, CGSize(width: 318, height: 278))
            XCTAssertEqual(frames[index].minX, 0)
            for olderIndex in frames.indices where olderIndex > index {
                XCTAssertFalse(frames[index].intersects(frames[olderIndex]))
                XCTAssertGreaterThan(frames[olderIndex].minY, frames[index].maxY)
            }
            if index > 0 { XCTAssertEqual(frames[index].minY - frames[index - 1].maxY, 12) }
        }
    }

    func testPanelAnchorsWithinDisplayWithNegativeOrigin() {
        let display = CGRect(x: -1920, y: -800, width: 1920, height: 1050)
        let panel = PreviewStackLayout.panelFrame(visibleFrame: display, count: 2)
        XCTAssertEqual(panel, CGRect(x: -1898, y: -778, width: 318, height: 568))
        XCTAssertTrue(display.contains(panel))
    }

    func testShortScreenClampsPanelWithoutDiscardingOverflowingCards() throws {
        let display = CGRect(x: 50, y: 70, width: 800, height: 400)
        let panel = PreviewStackLayout.panelFrame(visibleFrame: display, count: 10)
        XCTAssertEqual(panel, CGRect(x: 72, y: 92, width: 318, height: 356))
        XCTAssertTrue(display.contains(panel))
        XCTAssertEqual(PreviewStackLayout.documentHeight(count: 10), 2888)
        XCTAssertEqual(try XCTUnwrap(PreviewStackLayout.cardFrames(count: 10).last).maxY, 2888,
                       "The scroll document must keep every card even when the panel fits only one.")
        XCTAssertGreaterThan(PreviewStackLayout.documentHeight(count: 10), panel.height)
    }

    func testNarrowPanelWidthFitsBetweenDisplayMargins() {
        let display = CGRect(x: -300, y: 10, width: 300, height: 900)
        let panel = PreviewStackLayout.panelFrame(visibleFrame: display, count: 1)
        XCTAssertEqual(panel, CGRect(x: -278, y: 32, width: 256, height: 278))
        XCTAssertTrue(display.contains(panel))
    }

    func testTinyAndZeroViewportsNeverProduceNegativeSizesOrOutOfBoundsOrigins() {
        let viewports = [CGRect(x: 10, y: 20, width: 40, height: 30),
                         CGRect(x: -50, y: -40, width: 0, height: 0),
                         CGRect(x: 15, y: 30, width: 10, height: 200)]
        for viewport in viewports {
            let panel = PreviewStackLayout.panelFrame(visibleFrame: viewport, count: 10)
            XCTAssertGreaterThanOrEqual(panel.width, 0)
            XCTAssertGreaterThanOrEqual(panel.height, 0)
            XCTAssertGreaterThanOrEqual(panel.minX, viewport.minX)
            XCTAssertGreaterThanOrEqual(panel.minY, viewport.minY)
            XCTAssertLessThanOrEqual(panel.maxX, viewport.maxX)
            XCTAssertLessThanOrEqual(panel.maxY, viewport.maxY)
        }
        XCTAssertEqual(PreviewStackLayout.panelFrame(visibleFrame: viewports[0], count: 10),
                       CGRect(x: 30, y: 35, width: 0, height: 0))
    }
}
