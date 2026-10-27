// PelicanFloat — a pelican riding a bike in a floating window.
// A transparent borderless window hosts a WKWebView running app/pelican.html.
// Reads ~/.hermes/state.db every second: live turn pedals, more tokens, faster.
// No third-party deps, only the system's AppKit / WebKit / SQLite.

import Cocoa
import WebKit
import SQLite3
import ServiceManagement

// MARK: - Read Hermes usage

/// Reads Hermes' state.db directly: read-only, no writes, no helper process.
/// Opened and prepared once, reset per tick, so the 1 Hz poll stays cheap.
final class HermesUsage {
    let dbPath: String
    private var db: OpaquePointer?
    private var tokensStmt: OpaquePointer?
    private var busyStmt: OpaquePointer?

    private let sqlTokens = """
        SELECT COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens
                            + cache_write_tokens + reasoning_tokens), 0),
               COALESCE(MAX(last_seen), 0)
        FROM session_model_usage;
        """
    private let sqlBusy = "SELECT COUNT(*) FROM session_turn_leases WHERE expires_at > ?;"

    init(dbPath: String = ProcessInfo.processInfo.environment["PELICAN_DB"]
                     ?? NSString(string: "~/.hermes/state.db").expandingTildeInPath) {
        self.dbPath = dbPath
    }

    deinit { close() }

    private func openIfNeeded() -> Bool {
        if db != nil { return true }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            close()
            return false
        }
        sqlite3_busy_timeout(db, 300)
        guard sqlite3_prepare_v2(db, sqlTokens, -1, &tokensStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, sqlBusy, -1, &busyStmt, nil) == SQLITE_OK else {
            close()
            return false
        }
        return true
    }

    /// Reached when the db is gone, swapped or wedged; next tick reopens it.
    private func close() {
        sqlite3_finalize(tokensStmt); tokensStmt = nil
        sqlite3_finalize(busyStmt); busyStmt = nil
        sqlite3_close(db); db = nil
    }

    /// Reset right after reading: with two statements alternating, one left on
    /// ROW pins the read txn, so later reads see the open-time snapshot.
    private func reset(_ stmt: OpaquePointer?) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    /// Total tokens, plus when the newest usage row was written.
    func tokens() -> (total: Int64, lastSeen: Double)? {
        guard openIfNeeded(), let st = tokensStmt else { return nil }
        reset(st)
        guard sqlite3_step(st) == SQLITE_ROW else {
            close()   // drop a dead handle, rebuild next tick
            return nil
        }
        let out = (sqlite3_column_int64(st, 0), sqlite3_column_double(st, 1))
        reset(st)
        return out
    }

    /// Any unexpired turn lease means work is running.
    func isBusy(now: Double = Date().timeIntervalSince1970) -> Bool {
        guard openIfNeeded(), let st = busyStmt else { return false }
        reset(st)
        sqlite3_bind_double(st, 1, now)
        guard sqlite3_step(st) == SQLITE_ROW else {
            close()
            return false
        }
        let busy = sqlite3_column_int(st, 0) > 0
        reset(st)
        return busy
    }
}

// MARK: - Watch local agents

/// Agent log formats differ, but all of them append while working.
/// Real usage fields first, bytes as fallback, so format drift can't blind us.
/// Extra roots go in app/agents.txt, one per line, kept out of the repo.
final class AgentWatch {
    private struct FileState {
        var size: Int64
        var mtime: Date
        var parsed: Int64 = 0   // bytes consumed; only whole lines count
        var tokens = 0   // tokens this session reported so far
        var hasUsage = false   // whether real usage fields were found
        var cumulative = false   // once a running total appears, trust only it
        var lastKey: String?   // last counted message id, duplicates skipped
    }

    private var roots: [String]
    private var known: [String: FileState] = [:]
    private(set) var lastWriting = Date.distantPast
    private(set) var lastBytes = 0
    private(set) var lastTokens = 0
    private(set) var trackedCount = 0   // files watched now, for --probe

    /// Only used when no usage field exists: new bytes / 6.
    private let bytesPerToken: Double = 6

    init() {
        if let custom = ProcessInfo.processInfo.environment["PELICAN_AGENT_DIRS"] {
            roots = custom.split(separator: ":").map(String.init)
        } else {
            let home = NSString(string: "~").expandingTildeInPath
            roots = ["\(home)/.codex/sessions",      // OpenAI Codex CLI
                     "\(home)/.claude/projects"]     // Claude Code
            roots += Self.extraRoots(home: home)
        }
    }

    /// Watch the extra directories listed in a bundled app/agents.txt.
    private static func extraRoots(home: String) -> [String] {
        guard let url = Bundle.main.url(forResource: "agents", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.replacingOccurrences(of: "~", with: home) }
    }

    /// Per tick: bytes appended, and whether it is still writing.
    func sample(now: Date = Date()) -> (bytes: Int, writing: Bool) {
        var added = 0
        var writing = false

        // One stat per known file per tick, cheap at 1 Hz.
        var gone: [String] = []
        var fresh: [String: FileState] = [:]
        var tokens = 0   // real token delta this tick
        var fallback = 0   // bytes-based estimate for files without usage
        for (path, prev) in known {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = a[.size] as? Int64,
                  let mtime = a[.modificationDate] as? Date else {
                gone.append(path)   // file is gone
                continue
            }
            var st = prev
            st.size = size
            st.mtime = mtime
            // Truncated: restart at the new end, never replay history.
            if size < prev.size { st = FileState(size: size, mtime: mtime, parsed: size) }
            if size > prev.size {
                let grew = Int(min(size - prev.size, 8 << 20))
                added += grew
                let gained = Self.drainUsage(path: path, state: &st)
                if st.hasUsage { tokens += gained } else { fallback += grew }
            }
            fresh[path] = st
            if now.timeIntervalSince(mtime) < 8 { writing = true }
        }
        for p in gone { known[p] = nil }
        known.merge(fresh) { _, new in new }

        // Full walk every second: new session files must show up at once.
        for f in discover(now: now) where known[f.path] == nil {
            known[f.path] = FileState(size: f.size, mtime: f.mtime, parsed: f.size)
            if now.timeIntervalSince(f.mtime) < 8 { writing = true }
        }

        // Drop files quiet for an hour, or the map grows forever.
        known = known.filter { now.timeIntervalSince($0.value.mtime) < 3600 }

        if writing { lastWriting = now }
        lastBytes = added
        lastTokens = tokens + fallback / Int(bytesPerToken)
        trackedCount = known.count
        return (added, writing)
    }

    /// Tokens per second this tick: real counts first, bytes as fallback.
    func tokensPerSecond(dt: Double) -> Double {
        Double(lastTokens) / max(0.2, dt)
    }

    /// Read only the appended part, whole lines only; skip lines without usage.
    private static func drainUsage(path: String, state: inout FileState) -> Int {
        guard state.size > state.parsed else { return 0 }
        if state.size - state.parsed > 4 << 20 { state.parsed = state.size - (4 << 20) }
        // Unreadable for now: leave parsed alone so the next tick can retry.
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return 0 }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: UInt64(state.parsed))) != nil,
              let chunk = try? fh.read(upToCount: Int(state.size - state.parsed)),
              !chunk.isEmpty else { return 0 }
        guard let nl = chunk.lastIndex(of: UInt8(ascii: "\n")) else {
            // no newline yet: skip the tail instead of rereading it
            state.parsed = max(state.parsed, state.size - 65_536)
            return 0
        }
        let body = chunk[chunk.startIndex...nl]
        state.parsed += Int64(body.count)
        var gained = 0
        for line in body.split(separator: UInt8(ascii: "\n")) {
            let data = Data(line)
            guard data.range(of: usageKey) != nil, let hit = usage(line: data) else { continue }
            switch hit.kind {
            case .cumulative(let v):
                state.hasUsage = true
                if !state.cumulative {   // first total seen here is new
                    state.cumulative = true
                    state.tokens = v
                    gained += v
                } else if v > state.tokens {
                    gained += v - state.tokens
                    state.tokens = v
                }
            case .perMessage(let v):
                guard !state.cumulative, hit.key != state.lastKey else { continue }
                state.hasUsage = true
                state.lastKey = hit.key
                state.tokens += v
                gained += v
            }
        }
        return gained
    }

    private enum Kind { case cumulative(Int), perMessage(Int) }
    private struct Hit { let kind: Kind; let key: String? }
    private static let usageKey = Data("usage".utf8)   // cheap gate before JSON

   /// codex: running total, claude: per message; search recursively.
    private static func usage(line: Data) -> Hit? {
        guard line.count > 16,
              let obj = try? JSONSerialization.jsonObject(with: line) else { return nil }
        return find(obj)
    }

    private static func find(_ node: Any) -> Hit? {
        if let d = node as? [String: Any] {
            if let total = d["total_token_usage"] as? [String: Any],
               let v = total["total_tokens"] as? Int, v > 0 {
                return Hit(kind: .cumulative(v), key: nil)
            }
            if let u = d["usage"] as? [String: Any] {
                let sum = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .compactMap { u[$0] as? Int }.reduce(0, +)
                if sum > 0 { return Hit(kind: .perMessage(sum), key: d["id"] as? String) }
            }
            for (k, v) in d where k != "usage" {
                if let hit = find(v) { return hit }
            }
        } else if let a = node as? [Any] {
            for v in a { if let hit = find(v) { return hit } }
        }
        return nil
    }

    private struct Candidate { let path: String; let size: Int64; let mtime: Date }
    private static let exts: Set<String> = ["jsonl", "json", "log"]

    /// A directory's mtime only gates the files in it, never the descent:
    /// codex is sessions/YYYY/MM/DD and the year/month dirs stay old for weeks.
    private func discover(now: Date) -> [Candidate] {
        var out: [Candidate] = []
        let fm = FileManager.default
        let staleBefore = now.addingTimeInterval(-3600)

        func modified(_ path: String) -> Date? {
            (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }

        func walk(_ dir: String, depth: Int) {
            guard depth >= 0, let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            let fresh = (modified(dir) ?? .distantPast) > staleBefore
            for name in items {
                if name.hasPrefix(".") || name == "node_modules" { continue }
                let full = (dir as NSString).appendingPathComponent(name)
                if known[full] != nil { continue }   // tracked: skip stat
                guard let a = try? fm.attributesOfItem(atPath: full) else { continue }
                if a[.type] as? FileAttributeType == .typeDirectory {
                    walk(full, depth: depth - 1)
                } else if fresh, Self.exts.contains((name as NSString).pathExtension),
                          let size = a[.size] as? Int64,
                          let mtime = a[.modificationDate] as? Date,
                          now.timeIntervalSince(mtime) < 1800 {
                    out.append(Candidate(path: full, size: size, mtime: mtime))
                }
            }
        }

        for root in roots { walk(root, depth: 4) }
        return out
    }
}

// MARK: - Turn usage into pedalling speed

final class SpeedFeed {
    private let usage = HermesUsage()
    private let agents = AgentWatch()
    private var lastTotal: Int64?
    private var lastAt = Date()
    private(set) var rate: Double = 0   // tokens per second
    private(set) var working = false
    private var holdUntil: Double = 0

    /// A floor so the bike still turns while a live turn writes no tokens.
    // A lease means the turn runs, but usage rows only land at call ends, so
    // hold 24 tok/s in the gaps, which sits in bicycle gear (~272 px/s).
    private let idlePedalFloor: Double = 24
    /// How long after the last sign of work we still call it busy.
    private let holdSeconds: Double = 3

    /// Debug: files watched and bytes added in the last tick.
    var agentFiles: Int { agents.trackedCount }
    var hermesTotal: Int64? { lastTotal }   // feed's own total
    var agentBytes: Int { agents.lastBytes }
    var agentTokens: Int { agents.lastTokens }

    func tick() -> (rate: Double, working: Bool, hermes: Double, local: Double) {
        let now = Date()
        let ts = now.timeIntervalSince1970
        let dt = max(0.2, now.timeIntervalSince(lastAt))
        lastAt = now

        var raw: Double = 0
        var lastSeen: Double = 0
        if let snap = usage.tokens() {
            lastSeen = snap.lastSeen
            if let prev = lastTotal, snap.total >= prev {
                raw = Double(snap.total - prev) / dt
            }
            lastTotal = snap.total
        }

        // A lease, or usage in the last seconds, counts as work; the 3s grace
        // keeps the bike moving while the model is only thinking.
        let recent = ts - lastSeen < 6
        if usage.isBusy(now: ts) || recent { holdUntil = ts + holdSeconds }
        working = ts < holdUntil

        // Local agent log growth counts as spend too.
        let a = agents.sample(now: now)
        let localRaw = agents.tokensPerSecond(dt: dt)
        if a.writing || now.timeIntervalSince(agents.lastWriting) < 6 { holdUntil = max(holdUntil, ts + holdSeconds) }
        working = ts < holdUntil

        let combined = raw + localRaw
        let target = working ? max(combined, idlePedalFloor) : 0
        // Ease in fast while working (0.3), leave faster (0.5), page coasts.
        rate += (target - rate) * (working ? 0.3 : 0.5)
        if !working && rate < 0.5 { rate = 0 }
        return (rate, working, raw, localRaw)
    }
}

// MARK: - Draggable web view

final class PetWebView: WKWebView {
    enum Grip { case move, br, bl, tr, tl }

    private let gripZone: CGFloat = 26
    private var grip: Grip = .move
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero
    private var dragging = false

    var aspect: CGFloat = 1200.0 / 700.0
    var onResizeEnd: ((CGFloat) -> Void)?

    // Pure: frame after dragging a corner by dx. Split out to be testable.
    static func resizeFrame(start: NSRect, dx: CGFloat, grip: Grip, aspect: CGFloat,
                            minWidth: CGFloat = 320, maxWidth: CGFloat = 1400) -> NSRect {
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
        let f = PetWebView.resizeFrame(start: startFrame, dx: dx, grip: grip, aspect: aspect)
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

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var panel: PetPanel!
    private var web: PetWebView!
    private var statusItem: NSStatusItem!
    private var feed = SpeedFeed()
    private var timer: Timer?
    private var sentRate: Double = -1   // last value pushed to the page
    private var sentWorking = false
    private var sizeItems: [NSMenuItem] = []   // ticked like the live window
    private var loginItem: NSMenuItem?

    /// Only cross into JS when the value actually changed.
    private func push(_ s: (rate: Double, working: Bool, hermes: Double, local: Double)) {
        if abs(s.rate - sentRate) > 0.5 || s.working != sentWorking {
            let js = String(format: "window.pelican && pelican.setTokenRate(%.1f);", s.rate)
            web.evaluateJavaScript(js, completionHandler: nil)
            sentRate = s.rate
            sentWorking = s.working
        }
    }

    private let aspect: CGFloat = 1200.0 / 700.0
    private let sizes: [(String, CGFloat)] = [("小", 480), ("中", 680), ("大", 900)]

    /// --probe / --probe=N: log one sample per second, N seconds (default 10).
    private var isProbe: Bool {
        CommandLine.arguments.contains { $0 == "--probe" || $0.hasPrefix("--probe=") }
    }
    private var probeSeconds: Int {
        for a in CommandLine.arguments where a.hasPrefix("--probe=") {
            return max(1, Int(a.dropFirst("--probe=".count)) ?? 10)
        }
        return 10
    }

    /// Debug runs (--probe / --shot / --resize-test) must not touch saved
    /// window state, or a screenshot would overwrite the user's position.
    private var isDebugRun: Bool { CommandLine.arguments.contains { $0.hasPrefix("--") } }

    // --shot <path>: render one frame to a file, to check the page inside app.
    private var shotPath: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--shot"), a.count > i + 1 else { return nil }
        return a[i + 1]
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        buildWindow()
        buildMenu()
        // --probe samples on its own timer; a second one would eat the deltas.
        if !isProbe { startPolling() }

        if let path = shotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.snapshot(to: path) }
        }
        if CommandLine.arguments.contains("--resize-test") {
            let base = NSRect(x: 800, y: 200, width: 680, height: 397)
            let cases: [(PetWebView.Grip, CGFloat)] = [(.br, 120), (.br, -400), (.bl, 120), (.tr, -200), (.tl, -200)]
            for (g, dx) in cases {
                let f = PetWebView.resizeFrame(start: base, dx: dx, grip: g, aspect: aspect)
                NSLog("resize \(g) dx=\(Int(dx)) → x=\(Int(f.minX)) y=\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))")
            }
            exit(0)
        }
        if isProbe {
            let n = probeSeconds
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i)) {
                    let s = self.feed.tick()
                    self.push(s)   // probe drives the page too, so fps means something
                    let u = HermesUsage()
                    let t = u.tokens()
                    NSLog(String(format: "probe %d: rate=%.1f (hermes %.1f + local %.1f) working=%@ lease=%@ files=%d bytes=%d localTok=%d tokens=%lld feedTok=%lld",
                                 i, s.rate, s.hermes, s.local, s.working ? "yes" : "no",
                                 u.isBusy() ? "yes" : "no", self.feed.agentFiles,
                                 self.feed.agentBytes, self.feed.agentTokens, t?.total ?? -1,
                                 self.feed.hermesTotal ?? -1))
                    self.web.evaluateJavaScript("JSON.stringify(window.pelican.getState())") { v, _ in
                        NSLog("probe \(i) page: \(v as? String ?? "no api")")
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) + 1.0) { exit(0) }
        }
    }

    // window
    private func buildWindow() {
        let defaults = UserDefaults.standard
        let width = CGFloat(defaults.double(forKey: "width") == 0 ? 480 : defaults.double(forKey: "width"))
        let rect = NSRect(x: 0, y: 0, width: width, height: (width / aspect).rounded())

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
        web.navigationDelegate = self
        web.aspect = aspect
        web.onResizeEnd = { w in
            if !self.isDebugRun { UserDefaults.standard.set(Double(w), forKey: "width") }
            self.keepOnScreen()
            self.saveFrame()
        }
        panel.contentView = web

        if let saved = defaults.string(forKey: "origin") {
            let p = NSPointFromString(saved)
            panel.setFrameOrigin(p)
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - rect.width - 40, y: f.minY + 60))
        }
        keepOnScreen()
        loadPage()
        panel.orderFrontRegardless()

        guard !isDebugRun else { return }
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
        // Frame rate can be capped by env var, for power measurements.
        let fps = ProcessInfo.processInfo.environment["PELICAN_FPS"]
        comps?.fragment = fps.map { "app=1&fps=\($0)" } ?? "app=1"
        web.loadFileURL(comps?.url ?? url, allowingReadAccessTo: url.deletingLastPathComponent())
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
        guard !isDebugRun else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "origin")
    }

    // menu
    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bicycle", accessibilityDescription: "鹈鹕")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self

        let toggle = NSMenuItem(title: "显示 / 隐藏 鹈鹕", action: #selector(toggleVisible), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let sizeMenu = NSMenu()
        for (i, s) in sizes.enumerated() {
            let item = NSMenuItem(title: "\(s.0)（\(Int(s.1))×\(Int((s.1 / aspect).rounded()))）",
                                  action: #selector(pickSize(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            sizeMenu.addItem(item)
            sizeItems.append(item)
        }
        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let login = NSMenuItem(title: "开机自启", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        let w = sizes[sender.tag].1
        let f = panel.frame
        let new = NSRect(x: f.origin.x, y: f.origin.y, width: w, height: (w / aspect).rounded())
        panel.setFrame(new, display: true, animate: false)
        web.frame = NSRect(origin: .zero, size: new.size)
        UserDefaults.standard.set(Double(w), forKey: "width")
        keepOnScreen()
        saveFrame()
    }

    /// The menu switch: the app registers itself, no plist to write by hand.
    private var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLogin() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("开机自启没切成: \(error.localizedDescription)")
        }
    }

    // Push the speed into the page once a second.
    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = self.feed.tick()
            self.push(s)
            self.statusItem.button?.toolTip = s.working
                ? String(format: "任务中 · %.0f tok/s", s.rate)
                : "空闲 · 看风景"
        }
        timer?.tolerance = 0.2
    }

    // Render one frame to a file (self-check).
    private func snapshot(to path: String) {
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
            NSLog("截图已写入 \(path)  窗口=\(NSStringFromRect(self.panel.frame)) 层级=\(self.panel.level.rawValue)")
            exit(0)
        }
    }
}

// Ticks follow the live window: a corner drag changes the width behind our back.
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let w = panel.frame.width
        for (i, item) in sizeItems.enumerated() {
            item.state = abs(w - sizes[i].1) < 1 ? .on : .off
        }
        loginItem?.state = loginEnabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
