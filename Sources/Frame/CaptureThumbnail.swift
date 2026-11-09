import AppKit

enum CaptureThumbnail {
    /// Keep preview stacks lightweight while the original capture stays on disk.
    static func image(from image: CGImage, maxDimension: Int = 960) -> NSImage {
        let limit = max(1, maxDimension)
        let scale = min(1, CGFloat(limit) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard width != image.width || height != image.height else {
            return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else {
            return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else {
            return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
        return NSImage(cgImage: thumbnail, size: CGSize(width: width, height: height))
    }
}
