import CoreGraphics

/// Selection geometry independent of the overlay's mouse and keyboard events.
/// Anchor and endpoint retain their orientation when the normalized rect moves.
struct SelectionDrag {
    private(set) var rect: CGRect
    private(set) var isMoving = false

    private let bounds: CGRect
    private var anchor: CGPoint
    private var endpoint: CGPoint
    private var lastPointer: CGPoint
    private var resizeOffset = CGPoint.zero

    init(start: CGPoint, bounds: CGRect) {
        let bounds = bounds.standardized
        self.bounds = bounds
        let anchor = CGPoint(x: min(max(start.x, bounds.minX), bounds.maxX),
                             y: min(max(start.y, bounds.minY), bounds.maxY))
        self.anchor = anchor
        self.endpoint = anchor
        self.lastPointer = start
        self.rect = CGRect(origin: anchor, size: .zero)
    }

    mutating func update(pointer: CGPoint) {
        if isMoving {
            // Clamp the translation as a whole, preserving the selected extent.
            let dx = min(max(pointer.x - lastPointer.x, bounds.minX - rect.minX),
                         bounds.maxX - rect.maxX)
            let dy = min(max(pointer.y - lastPointer.y, bounds.minY - rect.minY),
                         bounds.maxY - rect.maxY)
            anchor.x += dx
            anchor.y += dy
            endpoint.x += dx
            endpoint.y += dy
        } else {
            endpoint = CGPoint(x: min(max(pointer.x + resizeOffset.x, bounds.minX), bounds.maxX),
                               y: min(max(pointer.y + resizeOffset.y, bounds.minY), bounds.maxY))
        }
        lastPointer = pointer
        rect = CGRect(x: min(anchor.x, endpoint.x), y: min(anchor.y, endpoint.y),
                      width: abs(endpoint.x - anchor.x), height: abs(endpoint.y - anchor.y))
    }

    mutating func setMoving(_ moving: Bool, pointer: CGPoint) {
        guard moving != isMoving else { return }
        // A modifier event may arrive before the next drag event. Commit its
        // latest pointer position under the old mode before switching modes.
        update(pointer: pointer)
        isMoving = moving
        if !moving {
            // Moving can hit a display edge while the pointer travels beyond it.
            // Preserve the endpoint at release, then resize relative to it.
            resizeOffset = CGPoint(x: endpoint.x - pointer.x, y: endpoint.y - pointer.y)
        }
    }
}
