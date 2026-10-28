import Cocoa
import SQLite3

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
