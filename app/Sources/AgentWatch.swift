import Cocoa

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
