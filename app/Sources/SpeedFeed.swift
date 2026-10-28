import Cocoa

/// One tick's verdict: what the page gets, and the two raw inputs behind it.
struct Snapshot {
    let rate: Double   // smoothed tokens/s handed to the page
    let working: Bool
    let hermes: Double   // raw tok/s from Hermes' state.db
    let local: Double   // raw tok/s from the other agents' logs
}

/// Two signals, one speed: Hermes' usage rows and the growth of any local
/// agent log. Whichever is spending tokens moves the pedals; no priority.
final class SpeedFeed {
    private let usage = HermesUsage()
    private let agents = AgentWatch()
    private var lastTotal: Int64?
    private var lastAt = Date()
    private(set) var rate: Double = 0   // tokens per second
    private var holdUntil: Double = 0

    /// A floor so the bike still turns while a live turn writes no tokens.
    // A lease means the turn runs, but usage rows only land at call ends, so
    // hold 24 tok/s in the gaps, which sits in bicycle gear (~272 px/s).
    private let idlePedalFloor: Double = 24
    /// How long after the last sign of work we still call it busy.
    private let holdSeconds: Double = 3

    // Read by --probe only: files watched and what the last tick found.
    var agentFiles: Int { agents.trackedCount }
    var hermesTotal: Int64? { lastTotal }   // feed's own total
    var agentBytes: Int { agents.lastBytes }
    var agentTokens: Int { agents.lastTokens }

    func tick() -> Snapshot {
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

        // Local agent log growth counts as spend too.
        let a = agents.sample(now: now)
        let localRaw = agents.tokensPerSecond(dt: dt)
        if a.writing || now.timeIntervalSince(agents.lastWriting) < 6 {
            holdUntil = max(holdUntil, ts + holdSeconds)
        }
        let working = ts < holdUntil

        let combined = raw + localRaw
        let target = working ? max(combined, idlePedalFloor) : 0
        // Ease in fast while working (0.3), leave faster (0.5), page coasts.
        rate += (target - rate) * (working ? 0.3 : 0.5)
        if !working && rate < 0.5 { rate = 0 }
        return Snapshot(rate: rate, working: working, hermes: raw, local: localRaw)
    }
}
