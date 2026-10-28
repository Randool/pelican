import Cocoa

/// Where the panel was left: origin and width in UserDefaults.
/// Debug runs are read-only here, or a --shot would move the user's window.
final class WindowState {
    /// Width the window opens at before the user has picked a size.
    static let defaultWidth: CGFloat = 480

    private let defaults: UserDefaults
    private let saves: Bool

    init(saves: Bool, defaults: UserDefaults = .standard) {
        self.saves = saves
        self.defaults = defaults
    }

    var width: CGFloat {
        let w = CGFloat(defaults.double(forKey: "width"))
        return w == 0 ? Self.defaultWidth : w
    }

    var origin: NSPoint? {
        defaults.string(forKey: "origin").map(NSPointFromString)
    }

    func save(origin p: NSPoint) {
        guard saves else { return }
        defaults.set(NSStringFromPoint(p), forKey: "origin")
    }

    func save(width w: CGFloat) {
        guard saves else { return }
        defaults.set(Double(w), forKey: "width")
    }
}
