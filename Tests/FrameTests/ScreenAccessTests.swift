import XCTest
import ScreenCaptureKit
@testable import Frame

final class ScreenAccessTests: XCTestCase {
    func testUserDeclinedIsTheScreenPermissionFailure() {
        let error = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertTrue(CaptureEngine.isScreenPermissionError(error))
    }

    func testServiceAndConfigurationFailuresAreNotPermissionDenials() {
        let codes: [SCStreamError.Code] = [.internalError, .noDisplayList, .missingEntitlements, .invalidParameter,
                                          .failedToStart, .userStopped, .failedToStartMicrophoneCapture]
        for code in codes {
            let error = NSError(domain: SCStreamError.errorDomain, code: code.rawValue)
            XCTAssertFalse(CaptureEngine.isScreenPermissionError(error), "\(code) requires its own recovery guidance.")
        }
        XCTAssertFalse(CaptureEngine.isScreenPermissionError(NSError(domain: SCStreamError.errorDomain, code: -1)))
        XCTAssertFalse(CaptureEngine.isScreenPermissionError(CancellationError()))
    }

    func testMatchingNumberFromAnotherFrameworkDoesNotImplyScreenPermission() {
        let error = NSError(domain: NSCocoaErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertFalse(CaptureEngine.isScreenPermissionError(error))
    }

    func testWrappedScreenPermissionFailureIsRecognized() {
        let cause = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let wrapper = NSError(domain: "Frame.Capture", code: 7, userInfo: [NSUnderlyingErrorKey: cause])
        XCTAssertTrue(CaptureEngine.isScreenPermissionError(wrapper))
    }

    func testWrappedServiceFailureRemainsAServiceFailure() {
        let cause = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.internalError.rawValue)
        let wrapper = NSError(domain: "Frame.Capture", code: 7, userInfo: [NSUnderlyingErrorKey: cause])
        XCTAssertFalse(CaptureEngine.isScreenPermissionError(wrapper))
    }
}
