import Cocoa

/// The switches used while working on the widget, parsed once at launch.
/// Any --flag makes this a debug run: it must not touch saved window state.
struct Launch {
    private let args: [String]

    init(args: [String] = CommandLine.arguments) { self.args = args }

    var isDebug: Bool { args.contains { $0.hasPrefix("--") } }

    var isProbe: Bool { args.contains { $0 == "--probe" || $0.hasPrefix("--probe=") } }

    /// --probe=N logs N seconds; a bare --probe means ten.
    var probeSeconds: Int {
        for a in args where a.hasPrefix("--probe=") {
            return max(1, Int(a.dropFirst("--probe=".count)) ?? 10)
        }
        return 10
    }

    /// --shot <path>: render one frame to a file, to check the page in-app.
    var shotPath: String? {
        guard let i = args.firstIndex(of: "--shot"), args.count > i + 1 else { return nil }
        return args[i + 1]
    }

    /// --resize-test: print the corner-drag maths and exit, no window needed.
    var isResizeTest: Bool { args.contains("--resize-test") }

    /// Frame rate cap for power measurements; nil lets the page adapt.
    var fpsCap: String? { ProcessInfo.processInfo.environment["PELICAN_FPS"] }
}
