import Cocoa
import WebKit

/// Wires the three parts together: the feed (tokens/s), the panel that shows
/// them, and the menu bar handle. Nothing else belongs here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launch = Launch()
    private let feed = SpeedFeed()
    private var state: WindowState!
    private var panel: PetPanel!
    private var web: PetWebView!
    private var menu: StatusMenu!
    private var timer: Timer?
    private var sent: Snapshot?   // last value pushed to the page

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        state = WindowState(saves: !launch.isDebug)
        buildPanel()
        buildMenu()

        if launch.isResizeTest {
            DebugRun.resizeTest()
            exit(0)
        }

        // A probe samples on its own timer; a second one would eat the deltas.
        if launch.isProbe {
            DebugRun.probe(seconds: launch.probeSeconds, feed: feed, web: web, push: push)
        } else {
            startPolling()
        }

        if let path = launch.shotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.snapshot(to: path) }
        }
    }

    // MARK: - window

    private func buildPanel() {
        let rect = Scene.rect(width: state.width)
        panel = PetPanel(contentRect: rect,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true   // shadow follows content alpha, corners too
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false

        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        web = PetWebView(frame: rect, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")   // no backdrop
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .clear }
        web.onResizeEnd = { [weak self] w in self?.didResize(to: w) }
        panel.contentView = web

        if let p = state.origin {
            panel.setFrameOrigin(p)
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - rect.width - 40, y: f.minY + 60))
        }
        keepOnScreen()
        loadPage()
        panel.orderFrontRegardless()

        guard !launch.isDebug else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(saveFrame),
                                              name: NSWindow.didMoveNotification, object: panel)
    }

    private func loadPage() {
        guard let url = Bundle.main.url(forResource: "pelican", withExtension: "html") else {
            NSLog("找不到 pelican.html")
            return
        }
        // Args go in the hash: file:// turns ?query into part of the filename.
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.fragment = launch.fpsCap.map { "app=1&fps=\($0)" } ?? "app=1"
        web.loadFileURL(comps?.url ?? url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func didResize(to width: CGFloat) {
        state.save(width: width)
        keepOnScreen()
        saveFrame()
    }

    /// Keep the panel on the display it lives on: clamping to NSScreen.main
    /// drags it off a second monitor the moment the user resizes.
    private func keepOnScreen() {
        let f = panel.frame
        let here = NSScreen.screens.first { $0.frame.contains(f.origin) }
        guard let v = (here ?? panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var o = f.origin
        o.x = min(max(o.x, v.minX), v.maxX - f.width)
        o.y = min(max(o.y, v.minY), v.maxY - f.height)
        panel.setFrameOrigin(o)
    }

    @objc private func saveFrame() {
        state.save(origin: panel.frame.origin)
    }

    // MARK: - menu

    private func buildMenu() {
        menu = StatusMenu(onToggle: { [weak self] in self?.toggleVisible() },
                          onPickWidth: { [weak self] w in self?.setWidth(w) },
                          liveWidth: { [weak self] in self?.panel?.frame.width ?? 0 })
    }

    private func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func setWidth(_ width: CGFloat) {
        let f = panel.frame
        let new = NSRect(x: f.origin.x, y: f.origin.y,
                         width: width, height: Scene.height(for: width))
        panel.setFrame(new, display: true, animate: false)
        web.frame = NSRect(origin: .zero, size: new.size)
        state.save(width: width)
        keepOnScreen()
        saveFrame()
    }

    // MARK: - feed

    // Push the speed into the page once a second.
    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = self.feed.tick()
            self.push(s)
            self.menu.tooltip = s.working
                ? String(format: "任务中 · %.0f tok/s", s.rate)
                : "空闲 · 看风景"
        }
        timer?.tolerance = 0.2
    }

    /// Only cross into JS when the value actually changed.
    private func push(_ s: Snapshot) {
        if let last = sent, abs(s.rate - last.rate) <= 0.5 && s.working == last.working { return }
        let js = String(format: "window.pelican && pelican.setTokenRate(%.1f);", s.rate)
        web.evaluateJavaScript(js, completionHandler: nil)
        sent = s
    }

    // Render one frame to a file (self-check).
    private func snapshot(to path: String) {
        DebugRun.snapshot(of: web, in: panel, to: path)
    }
}
