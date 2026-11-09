import CoreGraphics

/// Geometry for a bottom-anchored capture shelf. Document coordinates grow upward,
/// so index zero is the newest card and remains nearest the bottom of the screen.
enum PreviewStackLayout {
    static let cardSize = CGSize(width: 318, height: 278)
    static let gap: CGFloat = 12
    static let margin: CGFloat = 22

    static func documentHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * cardSize.height + CGFloat(count - 1) * gap
    }

    static func cardFrames(count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            CGRect(x: 0, y: CGFloat(index) * (cardSize.height + gap),
                   width: cardSize.width, height: cardSize.height)
        }
    }

    static func panelFrame(visibleFrame: CGRect, count: Int) -> CGRect {
        let visibleWidth = max(0, visibleFrame.width)
        let visibleHeight = max(0, visibleFrame.height)
        let width = min(cardSize.width, max(0, visibleWidth - 2 * margin))
        let height = min(documentHeight(count: count), max(0, visibleHeight - 2 * margin))
        return CGRect(x: visibleFrame.minX + min(margin, visibleWidth / 2),
                      y: visibleFrame.minY + min(margin, visibleHeight / 2),
                      width: width, height: height)
    }
}
