import Cocoa
import WebKit

/// The three debugging runs. They live apart from the app so the delegate
/// stays a wiring diagram, and so nothing here can leak into a normal launch.
enum DebugRun {
    /// --probe=N: one line a second, to compare the widget against a harness.
    /// Two HermesUsage handles on purpose: the feed's own total shows what it
    /// holds, a fresh one per tick shows the truth.
    static func probe(seconds: Int, feed: SpeedFeed, web: PetWebView,
                      push: @escaping (Snapshot) -> Void) {
        for i in 0..<seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i)) {
                let s = feed.tick()
                push(s)   // probe drives the page too, so fps means something
                let truth = HermesUsage()
                let total = truth.tokens()
                NSLog(String(format: "probe %d: rate=%.1f (hermes %.1f + local %.1f) working=%@ lease=%@ files=%d bytes=%d localTok=%d tokens=%lld feedTok=%lld",
                             i, s.rate, s.hermes, s.local, s.working ? "yes" : "no",
                             truth.isBusy() ? "yes" : "no", feed.agentFiles,
                             feed.agentBytes, feed.agentTokens, total?.total ?? -1,
                             feed.hermesTotal ?? -1))
                web.evaluateJavaScript("JSON.stringify(window.pelican.getState())") { v, _ in
                    NSLog("probe \(i) page: \(v as? String ?? "no api")")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds) + 1.0) { exit(0) }
    }

    /// --shot <path>: one frame of the real WKWebView, no screen recording.
    static func snapshot(of web: PetWebView, in panel: NSPanel, to path: String) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        web.takeSnapshot(with: cfg) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                NSLog("截图失败: \(String(describing: error))")
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: path))
            NSLog("截图已写入 \(path)  窗口=\(NSStringFromRect(panel.frame)) 层级=\(panel.level.rawValue)")
            exit(0)
        }
    }

    /// --resize-test: the corner maths, printed instead of dragged.
    static func resizeTest() {
        var base = Scene.rect(width: 680)
        base.origin = NSPoint(x: 800, y: 200)   // off-origin, so signs show
        let cases: [(PetWebView.Grip, CGFloat)] = [(.br, 120), (.br, -400), (.bl, 120), (.tr, -200), (.tl, -200)]
        for (g, dx) in cases {
            let f = PetWebView.resizeFrame(start: base, dx: dx, grip: g)
            NSLog("resize \(g) dx=\(Int(dx)) → x=\(Int(f.minX)) y=\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))")
        }
    }
}
