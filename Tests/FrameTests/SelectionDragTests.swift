import XCTest
@testable import Frame

final class SelectionDragTests: XCTestCase {
    func testEveryDragDirectionKeepsItsAnchorOrientationAfterMovingAndResuming() {
        let cases: [(end: CGPoint, moved: CGRect, resumedPointer: CGPoint, resumed: CGRect)] = [
            (.init(x: 260, y: 190), .init(x: 230, y: 130, width: 60, height: 40),
             .init(x: 315, y: 185), .init(x: 230, y: 130, width: 85, height: 55)),
            (.init(x: 140, y: 190), .init(x: 170, y: 130, width: 60, height: 40),
             .init(x: 145, y: 185), .init(x: 145, y: 130, width: 85, height: 55)),
            (.init(x: 260, y: 110), .init(x: 230, y: 90, width: 60, height: 40),
             .init(x: 315, y: 75), .init(x: 230, y: 75, width: 85, height: 55)),
            (.init(x: 140, y: 110), .init(x: 170, y: 90, width: 60, height: 40),
             .init(x: 145, y: 75), .init(x: 145, y: 75, width: 85, height: 55))
        ]
        for entry in cases {
            var drag = SelectionDrag(start: CGPoint(x: 200, y: 150),
                                     bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
            drag.update(pointer: entry.end)
            drag.setMoving(true, pointer: entry.end)
            let movedPointer = CGPoint(x: entry.end.x + 30, y: entry.end.y - 20)
            drag.update(pointer: movedPointer)
            XCTAssertEqual(drag.rect, entry.moved, "Initial endpoint: \(entry.end)")
            drag.setMoving(false, pointer: movedPointer)
            drag.update(pointer: entry.resumedPointer)
            XCTAssertEqual(drag.rect, entry.resumed, "Resizing must use the translated anchor: \(entry.end)")
        }
    }

    func testMovementClampsEntireRectangleToEachDisplayEdgeWithoutChangingSize() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        var drag = SelectionDrag(start: CGPoint(x: 50, y: 100), bounds: bounds)
        drag.update(pointer: CGPoint(x: 150, y: 180))
        drag.setMoving(true, pointer: CGPoint(x: 150, y: 180))

        drag.update(pointer: CGPoint(x: 1000, y: -1000))
        XCTAssertEqual(drag.rect, CGRect(x: 210, y: 20, width: 100, height: 80))
        XCTAssertTrue(bounds.contains(drag.rect))

        drag.update(pointer: CGPoint(x: -1000, y: 1000))
        XCTAssertEqual(drag.rect, CGRect(x: 10, y: 140, width: 100, height: 80))
        XCTAssertTrue(bounds.contains(drag.rect))
    }

    func testSpacePressAndReleaseCommitLatestPointerUnderPreviousMode() {
        var drag = SelectionDrag(start: CGPoint(x: 50, y: 100),
                                 bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        drag.update(pointer: CGPoint(x: 90, y: 140))
        drag.setMoving(true, pointer: CGPoint(x: 100, y: 150))
        XCTAssertTrue(drag.isMoving)
        XCTAssertEqual(drag.rect, CGRect(x: 50, y: 100, width: 50, height: 50))

        drag.update(pointer: CGPoint(x: 120, y: 175))
        XCTAssertEqual(drag.rect, CGRect(x: 70, y: 125, width: 50, height: 50))
        drag.setMoving(false, pointer: CGPoint(x: 130, y: 180))
        XCTAssertFalse(drag.isMoving)
        XCTAssertEqual(drag.rect, CGRect(x: 80, y: 130, width: 50, height: 50))
        drag.update(pointer: CGPoint(x: 130, y: 180))
        XCTAssertEqual(drag.rect, CGRect(x: 80, y: 130, width: 50, height: 50),
                       "The same pointer after releasing Space must not change the rectangle.")
    }

    func testSpaceReleaseOutsideDisplayDoesNotJumpAndResizingContinuesFromEndpoint() {
        var drag = SelectionDrag(start: CGPoint(x: 50, y: 100),
                                 bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        drag.update(pointer: CGPoint(x: 150, y: 180))
        drag.setMoving(true, pointer: CGPoint(x: 150, y: 180))
        drag.update(pointer: CGPoint(x: 900, y: 900))
        let atEdge = CGRect(x: 200, y: 120, width: 100, height: 80)
        XCTAssertEqual(drag.rect, atEdge)

        drag.setMoving(false, pointer: CGPoint(x: 920, y: 910))
        XCTAssertEqual(drag.rect, atEdge)
        drag.update(pointer: CGPoint(x: 920, y: 910))
        XCTAssertEqual(drag.rect, atEdge)
        drag.update(pointer: CGPoint(x: 910, y: 900))
        XCTAssertEqual(drag.rect, CGRect(x: 200, y: 120, width: 90, height: 70))
    }

    func testRepeatedSpaceEventsNeitherResetMovingOriginNorRebaseResizeOffset() {
        var drag = SelectionDrag(start: CGPoint(x: 30, y: 30),
                                 bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        drag.update(pointer: CGPoint(x: 70, y: 60))
        drag.setMoving(true, pointer: CGPoint(x: 70, y: 60))
        drag.update(pointer: CGPoint(x: 80, y: 80))
        let beforeRepeat = drag.rect
        drag.setMoving(true, pointer: CGPoint(x: 90, y: 90))
        XCTAssertEqual(drag.rect, beforeRepeat, "Repeated key-down is ignored, including its pointer.")
        drag.update(pointer: CGPoint(x: 100, y: 100))
        XCTAssertEqual(drag.rect, CGRect(x: 60, y: 70, width: 40, height: 30))

        drag.setMoving(false, pointer: CGPoint(x: 100, y: 100))
        let beforeReleaseRepeat = drag.rect
        drag.setMoving(false, pointer: CGPoint(x: 110, y: 110))
        XCTAssertEqual(drag.rect, beforeReleaseRepeat)
        drag.update(pointer: CGPoint(x: 120, y: 120))
        XCTAssertEqual(drag.rect, CGRect(x: 60, y: 70, width: 60, height: 50))
    }

    func testMouseReleasePositionWhileSpaceHeldMovesWithoutResizing() {
        var drag = SelectionDrag(start: CGPoint(x: 40, y: 60),
                                 bounds: CGRect(x: 0, y: 0, width: 500, height: 400))
        drag.update(pointer: CGPoint(x: 130, y: 150))
        drag.setMoving(true, pointer: CGPoint(x: 130, y: 150))
        drag.update(pointer: CGPoint(x: 170, y: 180))
        // The overlay uses the same update for the final mouse-up coordinate.
        drag.update(pointer: CGPoint(x: 190, y: 210))
        XCTAssertTrue(drag.isMoving)
        XCTAssertEqual(drag.rect, CGRect(x: 100, y: 120, width: 90, height: 90))
    }

    func testSpaceAtZeroSizeMovesAnchorAndResizesFromItsNewPositionAfterRelease() {
        var drag = SelectionDrag(start: CGPoint(x: 25, y: 35),
                                 bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        drag.setMoving(true, pointer: CGPoint(x: 25, y: 35))
        drag.update(pointer: CGPoint(x: 65, y: 85))
        XCTAssertEqual(drag.rect, CGRect(x: 65, y: 85, width: 0, height: 0))
        drag.setMoving(false, pointer: CGPoint(x: 65, y: 85))
        drag.update(pointer: CGPoint(x: 105, y: 115))
        XCTAssertEqual(drag.rect, CGRect(x: 65, y: 85, width: 40, height: 30))
    }

    func testFractionalRetinaPointsSurviveMovementAndResizing() {
        var drag = SelectionDrag(start: CGPoint(x: 75.5, y: 91.25),
                                 bounds: CGRect(x: 10.25, y: 20.5, width: 300, height: 200))
        drag.update(pointer: CGPoint(x: 130.75, y: 139.5))
        drag.setMoving(true, pointer: CGPoint(x: 130.75, y: 139.5))
        drag.update(pointer: CGPoint(x: 151.25, y: 129.25))
        XCTAssertEqual(drag.rect, CGRect(x: 96, y: 81, width: 55.25, height: 48.25))
        drag.setMoving(false, pointer: CGPoint(x: 151.25, y: 129.25))
        drag.update(pointer: CGPoint(x: 161.5, y: 134.75))
        XCTAssertEqual(drag.rect, CGRect(x: 96, y: 81, width: 65.5, height: 53.75))
    }

    func testInitialAnchorAndNormalResizeAreClampedToProvidedBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        var drag = SelectionDrag(start: CGPoint(x: -20, y: 500), bounds: bounds)
        XCTAssertEqual(drag.rect, CGRect(x: 10, y: 220, width: 0, height: 0))
        drag.update(pointer: CGPoint(x: 400, y: -50))
        XCTAssertEqual(drag.rect, bounds)
    }
}
