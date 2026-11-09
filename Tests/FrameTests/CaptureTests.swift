import XCTest
@testable import Frame

final class CaptureTests: XCTestCase {
    func testSelectionNormalizesEveryDragDirection() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let start = CGPoint(x: 150, y: 100)
        let cases: [(CGPoint, CGRect)] = [
            (CGPoint(x: 250, y: 160), CGRect(x: 150, y: 100, width: 100, height: 60)),
            (CGPoint(x: 50, y: 160), CGRect(x: 50, y: 100, width: 100, height: 60)),
            (CGPoint(x: 250, y: 40), CGRect(x: 150, y: 40, width: 100, height: 60)),
            (CGPoint(x: 50, y: 40), CGRect(x: 50, y: 40, width: 100, height: 60))
        ]
        for (end, expected) in cases {
            XCTAssertEqual(RegionGeometry.rectangle(from: start, to: end, bounds: bounds), expected,
                           "Drag to \(end) should preserve the same selected extent.")
        }
    }

    func testSelectionStaysWithinDisplayWhenPointerLeavesItsEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let start = CGPoint(x: 120, y: 80)
        XCTAssertEqual(RegionGeometry.rectangle(from: start, to: CGPoint(x: -90, y: -30), bounds: bounds),
                       CGRect(x: 0, y: 0, width: 120, height: 80))
        XCTAssertEqual(RegionGeometry.rectangle(from: start, to: CGPoint(x: 900, y: 600), bounds: bounds),
                       CGRect(x: 120, y: 80, width: 180, height: 120))
        XCTAssertEqual(RegionGeometry.rectangle(from: start, to: CGPoint(x: -90, y: 600), bounds: bounds),
                       CGRect(x: 0, y: 80, width: 120, height: 120))
        XCTAssertEqual(RegionGeometry.rectangle(from: start, to: CGPoint(x: 900, y: -30), bounds: bounds),
                       CGRect(x: 120, y: 0, width: 180, height: 80))
    }

    func testSelectionUsesProvidedBoundsOrigin() {
        // Geometry must not assume a display always begins at the primary screen's origin.
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(RegionGeometry.rectangle(from: CGPoint(x: 110, y: 120),
                                                to: CGPoint(x: -50, y: 500), bounds: bounds),
                       CGRect(x: 10, y: 120, width: 100, height: 100))
    }

    func testSourceRectangleFlipsBottomAndTopEdges() {
        XCTAssertEqual(RegionGeometry.sourceRect(localRect: CGRect(x: 35, y: 0, width: 100, height: 50),
                                                 screenHeight: 900),
                       CGRect(x: 35, y: 850, width: 100, height: 50))
        XCTAssertEqual(RegionGeometry.sourceRect(localRect: CGRect(x: 35, y: 850, width: 100, height: 50),
                                                 screenHeight: 900),
                       CGRect(x: 35, y: 0, width: 100, height: 50))
        XCTAssertEqual(RegionGeometry.sourceRect(localRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                 screenHeight: 900),
                       CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testSourceRectanglePreservesFractionalPointSelection() {
        XCTAssertEqual(RegionGeometry.sourceRect(localRect: CGRect(x: 12.5, y: 102.25, width: 200.5, height: 80.25),
                                                 screenHeight: 900),
                       CGRect(x: 12.5, y: 717.5, width: 200.5, height: 80.25))
    }

    func testVideoDimensionsArePositiveAndEvenAfterFractionalScaling() {
        let cases: [(CGFloat, Int)] = [(0, 2), (1, 2), (2, 2), (3, 2), (8.9, 8), (9.6, 10), (4095.9, 4096)]
        for (input, expected) in cases {
            let dimension = RegionGeometry.evenPixelDimension(input)
            XCTAssertEqual(dimension, expected)
            XCTAssertGreaterThanOrEqual(dimension, 2)
            XCTAssertEqual(dimension % 2, 0)
        }
    }

    func testAudioModeFlagsCoverExactlyRequestedInputs() {
        let expected: [(AudioMode, Bool, Bool)] = [
            (.none, false, false),
            (.microphone, true, false),
            (.system, false, true),
            (.both, true, true)
        ]
        XCTAssertEqual(Set(AudioMode.allCases.map(\.rawValue)), Set(expected.map { $0.0.rawValue }))
        for (mode, microphone, system) in expected {
            XCTAssertEqual(mode.includesMicrophone, microphone, mode.title)
            XCTAssertEqual(mode.includesSystemAudio, system, mode.title)
        }
    }

    func testLargeAndPortraitRecordingsFitEncoderBounds() {
        XCTAssertEqual(RegionGeometry.recordingPixelSize(native: CGSize(width: 1920, height: 1080)),
                       CGSize(width: 1920, height: 1080))
        XCTAssertEqual(RegionGeometry.recordingPixelSize(native: CGSize(width: 7680, height: 4320)),
                       CGSize(width: 4096, height: 2304))
        XCTAssertEqual(RegionGeometry.recordingPixelSize(native: CGSize(width: 2160, height: 3840)),
                       CGSize(width: 1296, height: 2304))
    }
}
