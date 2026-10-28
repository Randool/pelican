// PelicanFloat — a pelican riding a bike in a floating window.
// A transparent borderless panel hosts a WKWebView running app/pelican.html.
// Reads ~/.hermes/state.db every second: live turn pedals, more tokens, faster.
// System frameworks only: AppKit, WebKit, SQLite.

import Cocoa

/// The scene's shape, in one place: the page draws a 1200x700 viewBox and the
/// window must match it, or `preserveAspectRatio` silently crops the picture.
enum Scene {
    static let aspect: CGFloat = 1200.0 / 700.0
    /// Narrow enough to sit in a corner, wide enough to read the beach.
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 1400

    static func height(for width: CGFloat) -> CGFloat { (width / aspect).rounded() }

    static func rect(width: CGFloat) -> NSRect {
        NSRect(x: 0, y: 0, width: width, height: height(for: width))
    }
}
