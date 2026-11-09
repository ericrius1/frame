import AppKit

enum CaptureKind: String {
    case screenshot, recording
}

enum AudioMode: String, CaseIterable, Identifiable {
    case none, microphone, system, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .microphone: return "Microphone"
        case .system: return "System audio"
        case .both: return "Microphone + system"
        }
    }
    var symbol: String {
        switch self {
        case .none: return "speaker.slash"
        case .microphone: return "mic"
        case .system: return "speaker.wave.2"
        case .both: return "waveform"
        }
    }
    var detail: String {
        switch self {
        case .none: return "A silent screen recording."
        case .microphone: return "Your voice from the default microphone."
        case .system: return "The sound playing on your Mac."
        case .both: return "Your voice and Mac audio, together."
        }
    }
    var includesMicrophone: Bool { self == .microphone || self == .both }
    var includesSystemAudio: Bool { self == .system || self == .both }
}

/// Rect is in the chosen screen's local, bottom-left AppKit point coordinates.
struct CaptureRegion {
    let screen: NSScreen
    let rect: CGRect
    var globalRect: CGRect { rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }
    var displayID: CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    var pixelSize: CGSize {
        CGSize(width: (rect.width * screen.backingScaleFactor).rounded(),
               height: (rect.height * screen.backingScaleFactor).rounded())
    }
}

struct CaptureItem: Identifiable {
    let id: UUID
    let kind: CaptureKind
    let url: URL
    let thumbnail: NSImage
    let pixelSize: CGSize
    let createdAt: Date
    let duration: TimeInterval?

    init(kind: CaptureKind, url: URL, thumbnail: NSImage, pixelSize: CGSize, duration: TimeInterval? = nil) {
        self.id = UUID()
        self.kind = kind
        self.url = url
        self.thumbnail = thumbnail
        self.pixelSize = pixelSize
        self.createdAt = Date()
        self.duration = duration
    }
}

enum CaptureFiles {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("Frame/Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static func newURL(kind: CaptureKind) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Frame \(kind == .screenshot ? "Screenshot" : "Recording") \(formatter.string(from: Date())) \(UUID().uuidString.prefix(4))"
        return try directory().appendingPathComponent(name).appendingPathExtension(kind == .screenshot ? "png" : "mp4")
    }
}

enum RegionGeometry {
    static func rectangle(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGRect {
        let clamped = CGPoint(x: min(max(end.x, bounds.minX), bounds.maxX),
                              y: min(max(end.y, bounds.minY), bounds.maxY))
        return CGRect(x: min(start.x, clamped.x), y: min(start.y, clamped.y),
                      width: abs(start.x - clamped.x), height: abs(start.y - clamped.y)).intersection(bounds)
    }
    /// ScreenCaptureKit's source rect uses a top-left origin within a display.
    static func sourceRect(localRect: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: localRect.minX, y: screenHeight - localRect.maxY,
               width: localRect.width, height: localRect.height)
    }
    static func evenPixelDimension(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded()) / 2 * 2)
    }
    static func recordingPixelSize(native: CGSize) -> CGSize {
        let scale = min(1, 4096 / max(1, native.width), 2304 / max(1, native.height))
        return CGSize(width: evenPixelDimension(native.width * scale),
                      height: evenPixelDimension(native.height * scale))
    }
}
