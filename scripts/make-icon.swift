import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? ".build/Frame.iconset"
let output = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    NSColor.clear.setFill()
    canvas.fill()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -13)
    shadow.set()
    let plate = NSBezierPath(roundedRect: CGRect(x: 76, y: 76, width: 872, height: 872), xRadius: 196, yRadius: 196)
    NSColor(red: 0.07, green: 0.10, blue: 0.12, alpha: 1).setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 0.13, green: 0.18, blue: 0.20, alpha: 1),
               ending: NSColor(red: 0.035, green: 0.055, blue: 0.075, alpha: 1))?.draw(in: plate, angle: -65)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    plate.lineWidth = 3
    plate.stroke()

    let mint = NSColor(red: 0.43, green: 0.91, blue: 0.77, alpha: 1)
    let shade = NSBezierPath(roundedRect: CGRect(x: 237, y: 300, width: 550, height: 424), xRadius: 26, yRadius: 26)
    mint.withAlphaComponent(0.045).setFill()
    shade.fill()
    mint.withAlphaComponent(0.20).setStroke()
    shade.lineWidth = 4
    shade.stroke()
    let corners: [[CGPoint]] = [
        [CGPoint(x: 240, y: 590), CGPoint(x: 240, y: 707), CGPoint(x: 357, y: 707)],
        [CGPoint(x: 667, y: 707), CGPoint(x: 784, y: 707), CGPoint(x: 784, y: 590)],
        [CGPoint(x: 784, y: 434), CGPoint(x: 784, y: 317), CGPoint(x: 667, y: 317)],
        [CGPoint(x: 357, y: 317), CGPoint(x: 240, y: 317), CGPoint(x: 240, y: 434)]
    ]
    mint.setStroke()
    for points in corners {
        let path = NSBezierPath()
        path.move(to: points[0])
        path.line(to: points[1])
        path.line(to: points[2])
        path.lineWidth = 34
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
    mint.withAlphaComponent(0.10).setFill()
    NSBezierPath(ovalIn: CGRect(x: 449, y: 449, width: 126, height: 126)).fill()
    mint.setFill()
    NSBezierPath(ovalIn: CGRect(x: 484, y: 484, width: 56, height: 56)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for logical in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 1 ? "" : "@2x"
        try renderIcon(pixels: logical * factor).write(to: output.appendingPathComponent("icon_\(logical)x\(logical)\(suffix).png"))
    }
}

