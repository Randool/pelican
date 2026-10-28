import Cocoa
import WebKit

/// A transparent, never-key panel; the window itself is the widget's body.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The page inside the panel. Drag anywhere to move, drag a corner to resize;
/// the window keeps the scene's aspect no matter which corner is pulled.
final class PetWebView: WKWebView {
    enum Grip { case move, br, bl, tr, tl }

    private let gripZone: CGFloat = 26
    private var grip: Grip = .move
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero
    private var dragging = false

    /// Called with the new width once a corner drag ends.
    var onResizeEnd: ((CGFloat) -> Void)?

    // Pure: frame after dragging a corner by dx. Split out to be testable.
    static func resizeFrame(start: NSRect, dx: CGFloat, grip: Grip,
                            aspect: CGFloat = Scene.aspect,
                            minWidth: CGFloat = Scene.minWidth,
                            maxWidth: CGFloat = Scene.maxWidth) -> NSRect {
        var w = start.width, x = start.origin.x, y = start.origin.y
        switch grip {
        case .br: w = start.width + dx
        case .tr: w = start.width + dx
        case .bl: w = start.width - dx; x = start.origin.x + dx
        case .tl: w = start.width - dx; x = start.origin.x + dx
        case .move: return start
        }
        w = min(maxWidth, max(minWidth, w))
        let h = (w / aspect).rounded()
        if grip == .tr || grip == .tl { y = start.maxY - h }   // top edge fixed
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func grip(at p: NSPoint) -> Grip {
        let b = bounds
        let l = p.x < gripZone, r = p.x > b.width - gripZone
        let bottom = p.y < gripZone, top = p.y > b.height - gripZone
        if r && bottom { return .br }
        if l && bottom { return .bl }
        if r && top { return .tr }
        if l && top { return .tl }
        return .move
    }

    // The panel is never key; without this the first click gets swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        grip = grip(at: convert(event.locationInWindow, from: nil))
        if grip == .move {   // not a corner: move the whole window
            window?.performDrag(with: event)
            return
        }
        startFrame = window?.frame ?? .zero
        startMouse = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard grip != .move, let win = window else { return }
        let dx = event.locationInWindow.x - startMouse.x
        let f = PetWebView.resizeFrame(start: startFrame, dx: dx, grip: grip)
        win.setFrame(f, display: true)
        dragging = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { onResizeEnd?(window?.frame.width ?? startFrame.width) }
        dragging = false
        grip = .move
    }

    // Resize cursor on the corners, so it reads as draggable.
    override func resetCursorRects() {
        super.resetCursorRects()
        let b = bounds, z = gripZone
        let corners: [(NSRect, NSCursor.FrameResizePosition)] = [
            (NSRect(x: b.width - z, y: 0, width: z, height: z), .bottomRight),
            (NSRect(x: 0, y: 0, width: z, height: z), .bottomLeft),
            (NSRect(x: b.width - z, y: b.height - z, width: z, height: z), .topRight),
            (NSRect(x: 0, y: b.height - z, width: z, height: z), .topLeft),
        ]
        for (rect, pos) in corners {
            if #available(macOS 15.0, *) {
                addCursorRect(rect, cursor: .frameResize(position: pos, directions: [.inward, .outward]))
            } else {
                addCursorRect(rect, cursor: .crosshair)
            }
        }
    }
}
