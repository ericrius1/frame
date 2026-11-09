import AppKit
import AVFoundation
import CoreVideo
import ScreenCaptureKit

/// ScreenCaptureKit owns the media clocks, audio mix, and MP4 finalization.
/// All lifecycle state is serialized on the main actor; delegate callbacks hop here.
@MainActor
final class CaptureEngine: NSObject {
    var onUnexpectedStop: ((Error) -> Void)?

    private enum CaptureError: LocalizedError {
        case unavailableDisplay, alreadyRecording, notRecording, emptyImage, emptyRecording
        case startTimedOut, finishTimedOut, stoppedExternally
        case screenAccessTimedOut, screenAccessUnavailable, noDisplays

        var errorDescription: String? {
            switch self {
            case .unavailableDisplay: return "The selected display is no longer connected. Select an area again."
            case .alreadyRecording: return "A recording is already in progress."
            case .notRecording: return "There is no active recording to stop."
            case .emptyImage: return "The screenshot could not be saved. Please try again."
            case .emptyRecording: return "The recording did not contain any video. Please try again."
            case .startTimedOut: return "Screen recording did not start. Check Screen Recording permission and try again."
            case .finishTimedOut: return "The recording did not finish saving. Please try a new recording."
            case .stoppedExternally: return "Screen recording was stopped by macOS."
            case .screenAccessTimedOut: return "macOS didn’t finish checking screen access. Try again, or quit and reopen Frame."
            case .screenAccessUnavailable: return "macOS couldn’t provide screen capture information. Try again, or quit and reopen Frame."
            case .noDisplays: return "No display is currently available to capture. Reconnect your display and try again."
            }
        }
    }

    @MainActor private final class Session {
        enum Phase { case starting, recording, stopping }
        let stream: SCStream
        let output: SCRecordingOutput
        let url: URL
        let pixelSize: CGSize
        var phase: Phase = .starting
        var result: Result<Void, Error>?
        var startWaiter: CheckedContinuation<Void, Error>?
        var finishWaiter: CheckedContinuation<Void, Error>?
        var timeout: Task<Void, Never>?

        init(stream: SCStream, output: SCRecordingOutput, url: URL, pixelSize: CGSize) {
            self.stream = stream
            self.output = output
            self.url = url
            self.pixelSize = pixelSize
        }
    }

    private var session: Session?

    /// Use the same authorized ScreenCaptureKit request as an actual capture. The
    /// current-process API deliberately returns redacted content without consent.
    func checkScreenAccess() async throws {
        _ = try await shareableContent()
    }

    nonisolated static func isScreenPermissionError(_ error: Error) -> Bool {
        func isUserDeclined(_ value: NSError) -> Bool {
            value.domain == SCStreamError.errorDomain && value.code == SCStreamError.Code.userDeclined.rawValue
        }
        let value = error as NSError
        if isUserDeclined(value) { return true }
        // Frameworks may wrap the actual capture failure. Inspect one underlying
        // error only, so malformed/cyclic error chains cannot recurse indefinitely.
        guard let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error else { return false }
        return isUserDeclined(underlying as NSError)
    }

    func screenshot(region: CaptureRegion) async throws -> CaptureItem {
        let filter = try await contentFilter(for: region)
        let configuration = configuration(for: region, recording: false)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.emptyImage }
        let url = try CaptureFiles.newURL(kind: .screenshot)
        try data.write(to: url, options: .atomic)
        return CaptureItem(kind: .screenshot, url: url,
                           thumbnail: CaptureThumbnail.image(from: image),
                           pixelSize: CGSize(width: image.width, height: image.height))
    }

    func startRecording(region: CaptureRegion, audio: AudioMode) async throws {
        guard session == nil else { throw CaptureError.alreadyRecording }
        let filter = try await contentFilter(for: region)
        // Recheck after awaiting shareable content, so concurrent callers cannot start twice.
        guard session == nil else { throw CaptureError.alreadyRecording }
        let configuration = configuration(for: region, recording: true)
        configuration.capturesAudio = audio.includesSystemAudio
        configuration.captureMicrophone = audio.includesMicrophone
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let url = try CaptureFiles.newURL(kind: .recording)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264

        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let current = Session(stream: stream, output: output, url: url,
                              pixelSize: CGSize(width: configuration.width, height: configuration.height))
        session = current
        do {
            try stream.addRecordingOutput(output)
            armTimeout(for: current, seconds: 15, error: CaptureError.startTimedOut)
            // A successful stream start does not imply the recording file has started yet.
            // Wait on the recording delegate, with a bounded callback-based start operation.
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                current.startWaiter = waiter
                stream.startCapture { [weak self, weak current] error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard let self, let current, self.session === current else { return }
                        self.fail(current, error: error)
                    }
                }
            }
            guard session === current else { throw CaptureError.stoppedExternally }
            if let result = current.result {
                try result.get()
                throw CaptureError.stoppedExternally
            }
            current.timeout?.cancel()
            current.timeout = nil
            current.phase = .recording
        } catch {
            current.timeout?.cancel()
            resolve(current, with: .failure(error))
            if session === current { session = nil }
            // Stop asynchronously: a broken capture service must not keep the UI busy.
            Task { try? await stream.stopCapture() }
            throw error
        }
    }

    func stopRecording() async throws -> CaptureItem {
        guard let current = session, current.phase == .recording else { throw CaptureError.notRecording }
        current.phase = .stopping
        armTimeout(for: current, seconds: 20, error: CaptureError.finishTimedOut)
        do {
            // stopCapture initiates flushing. didFinishRecording is the file-ready signal.
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                if let result = current.result { waiter.resume(with: result); return }
                current.finishWaiter = waiter
                current.stream.stopCapture { [weak self, weak current] error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard let self, let current, self.session === current else { return }
                        self.fail(current, error: error)
                    }
                }
            }
            current.timeout?.cancel()
            if session === current { session = nil }
            return try await makeRecordingItem(current)
        } catch {
            current.timeout?.cancel()
            resolve(current, with: .failure(error))
            if session === current { session = nil }
            Task { try? await current.stream.stopCapture() }
            throw recoveryError(error, url: current.url)
        }
    }

    private func contentFilter(for region: CaptureRegion) async throws -> SCContentFilter {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw CaptureError.unavailableDisplay
        }
        // Excluding the entire application also excludes panels created after the filter.
        let ownApplication = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: ownApplication, exceptingWindows: [])
    }

    private func shareableContent() async throws -> SCShareableContent {
        let request = ShareableContentRequest()
        let content = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { request.start($0) }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        withExtendedLifetime(request) {}
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }
        return content
    }

    @MainActor private final class ShareableContentRequest {
        private var continuation: CheckedContinuation<SCShareableContent, Error>?
        private var timeout: Task<Void, Never>?
        private var completed = false

        func start(_ continuation: CheckedContinuation<SCShareableContent, Error>) {
            guard !completed else {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            guard !Task.isCancelled else { cancel(); return }
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                self?.finish(.failure(CaptureError.screenAccessTimedOut))
            }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
                Task { @MainActor [weak self] in
                    guard let self, !self.completed else { return }
                    if let error { self.finish(.failure(error)) }
                    else if let content { self.finish(.success(content)) }
                    else { self.finish(.failure(CaptureError.screenAccessUnavailable)) }
                }
            }
        }

        func cancel() { finish(.failure(CancellationError())) }

        private func finish(_ result: Result<SCShareableContent, Error>) {
            guard !completed else { return }
            completed = true
            timeout?.cancel()
            timeout = nil
            let waiter = continuation
            continuation = nil
            waiter?.resume(with: result)
            // ScreenCaptureKit exposes no cancellation API for this query. Late
            // callbacks use a weak reference and cannot affect another attempt.
        }
    }

    private func configuration(for region: CaptureRegion, recording: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = RegionGeometry.sourceRect(localRect: region.rect, screenHeight: region.screen.frame.height)
        if recording {
            // H.264's broadly compatible 4K envelope; retain aspect ratio on very large Retina areas.
            let size = RegionGeometry.recordingPixelSize(native: region.pixelSize)
            configuration.width = Int(size.width)
            configuration.height = Int(size.height)
        } else {
            configuration.width = max(1, Int(region.pixelSize.width))
            configuration.height = max(1, Int(region.pixelSize.height))
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.showsCursor = recording
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureDynamicRange = .SDR
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.shouldBeOpaque = true
        return configuration
    }

    private func resolve(_ current: Session, with result: Result<Void, Error>) {
        guard current.result == nil else { return }
        current.result = result
        current.timeout?.cancel()
        current.timeout = nil
        if let waiter = current.startWaiter {
            current.startWaiter = nil
            waiter.resume(with: result)
        }
        if let waiter = current.finishWaiter {
            current.finishWaiter = nil
            waiter.resume(with: result)
        }
    }

    private func armTimeout(for current: Session, seconds: UInt64, error: Error) {
        current.timeout?.cancel()
        current.timeout = Task { [weak self, weak current] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self, let current, self.session === current else { return }
            self.fail(current, error: error)
        }
    }

    private func fail(_ current: Session, error: Error) {
        guard current.result == nil else { return }
        let wasRecording = current.phase == .recording
        resolve(current, with: .failure(error))
        if wasRecording {
            if session === current { session = nil }
            Task { try? await current.stream.stopCapture() }
            onUnexpectedStop?(recoveryError(error, url: current.url))
        }
    }

    private func makeRecordingItem(_ current: Session) async throws -> CaptureItem {
        let attributes = try FileManager.default.attributesOfItem(atPath: current.url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { throw CaptureError.emptyRecording }
        // didFinishRecording already established that the file is ready. Optional preview
        // metadata must never hold up that result, especially while the app is quitting.
        let seconds = current.output.recordedDuration.seconds
        let duration = seconds.isFinite && seconds > 0 ? seconds : nil
        let image = await recordingThumbnail(for: current.url)
            ?? NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Screen recording")
            ?? NSImage(size: CGSize(width: 320, height: 180))
        return CaptureItem(kind: .recording, url: current.url, thumbnail: image,
                           pixelSize: current.pixelSize, duration: duration)
    }

    private func recordingThumbnail(for url: URL) async -> NSImage? {
        let request = ThumbnailRequest(url: url)
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { request.start($0) }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        // Keep the request alive while its continuation is suspended. Callbacks use
        // weak captures so AVFoundation cannot retain an obsolete preview request.
        withExtendedLifetime(request) {}
        return image
    }

    @MainActor private final class ThumbnailRequest {
        private let generator: AVAssetImageGenerator
        private var continuation: CheckedContinuation<NSImage?, Never>?
        private var timeout: Task<Void, Never>?
        private var completed = false

        init(url: URL) {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 600)
        }

        func start(_ continuation: CheckedContinuation<NSImage?, Never>) {
            guard !completed, !Task.isCancelled else {
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                self?.finish(nil, cancelGeneration: true)
            }
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { [weak self] _, image, _, result, _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.completed else { return }
                    let thumbnail = result == .succeeded ? image.map { NSImage(cgImage: $0, size: .zero) } : nil
                    self.finish(thumbnail, cancelGeneration: false)
                }
            }
        }

        func cancel() {
            finish(nil, cancelGeneration: true)
        }

        private func finish(_ image: NSImage?, cancelGeneration: Bool) {
            guard !completed else { return }
            completed = true
            timeout?.cancel()
            timeout = nil
            let waiter = continuation
            continuation = nil
            waiter?.resume(returning: image)
            if cancelGeneration { generator.cancelAllCGImageGeneration() }
        }
    }

    private func didStart(_ output: SCRecordingOutput) {
        guard let current = session, current.output === output, current.result == nil else { return }
        current.timeout?.cancel()
        current.timeout = nil
        if let waiter = current.startWaiter {
            current.startWaiter = nil
            waiter.resume()
        }
    }

    private func didFinish(_ output: SCRecordingOutput) {
        guard let current = session, current.output === output, current.result == nil else { return }
        if current.phase == .starting {
            fail(current, error: CaptureError.emptyRecording)
            return
        }
        let stoppedExternally = current.phase == .recording
        resolve(current, with: .success(()))
        if stoppedExternally {
            session = nil
            Task { try? await current.stream.stopCapture() }
            onUnexpectedStop?(recoveryError(CaptureError.stoppedExternally, url: current.url))
        }
    }

    private func recoveryError(_ error: Error, url: URL) -> Error {
        NSError(domain: "Frame.Capture", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "\(error.localizedDescription)\n\nA recovery file may be available at:\n\(url.path)",
                           NSUnderlyingErrorKey: error,
                           NSFilePathErrorKey: url.path])
    }
}

extension CaptureEngine: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.didStart(recordingOutput) }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.didFinish(recordingOutput) }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, let current = self.session, current.output === recordingOutput else { return }
            self.fail(current, error: error)
        }
    }
}

extension CaptureEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, let current = self.session, current.stream === stream else { return }
            self.fail(current, error: error)
        }
    }
}
