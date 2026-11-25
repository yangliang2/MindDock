import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class DockEngine: @unchecked Sendable {
    public static let maxBerths = 3

    public static func defaultDatabasePath() -> String {
        if let override = ProcessInfo.processInfo.environment["MINDDOCK_DB_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("MindDock", isDirectory: true)
            .appendingPathComponent("minddock.sqlite3")
            .path
    }

    private let lock = NSLock()
    private var db: OpaquePointer?
    private var currentActiveLane: Lane = .work

    public init(databasePath: String) throws {
        if databasePath != ":memory:" {
            let parentDir = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databasePath, &handle, flags, nil) != SQLITE_OK {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database"
            if let handle { sqlite3_close(handle) }
            throw DockError.storageFailure(message)
        }
        self.db = handle

        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS dock_items (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                raw TEXT NOT NULL,
                lane TEXT NOT NULL,
                status TEXT NOT NULL,
                prep TEXT,
                prep_state TEXT NOT NULL,
                order_seq INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS dock_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)

        if let savedLane = try readMetaUnlocked(key: "active_lane"),
           let parsed = Lane(rawValue: savedLane) {
            self.currentActiveLane = parsed
        } else {
            try writeMetaUnlocked(key: "active_lane", value: Lane.work.rawValue)
            self.currentActiveLane = .work
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public var activeLane: Lane {
        lock.lock()
        defer { lock.unlock() }
        return currentActiveLane
    }

    @discardableResult
    public func drop(_ raw: String, lane: Lane? = nil) throws -> DockItem {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DockError.emptyDrop
        }

        lock.lock()
        defer { lock.unlock() }

        return try inTransaction {
            let resolvedLane = lane ?? Self.inferLaneLocally(for: raw)
            let dockedCount = try countItems(lane: resolvedLane, status: .docked)
            let newStatus: ItemStatus = dockedCount < Self.maxBerths ? .docked : .queued
            let orderSeq = try nextOrderSeqUnlocked()
            let now = Date()
            let item = DockItem(
                id: UUID().uuidString.lowercased(),
                raw: raw,
                lane: resolvedLane,
                status: newStatus,
                prep: nil,
                prepState: .pending,
                createdAt: now,
                updatedAt: now
            )

            try withStatement("""
                INSERT INTO dock_items (id, raw, lane, status, prep, prep_state, order_seq, created_at, updated_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
                """) { stmt in
                bindText(stmt, index: 1, value: item.id)
                bindText(stmt, index: 2, value: item.raw)
                bindText(stmt, index: 3, value: item.lane.rawValue)
                bindText(stmt, index: 4, value: item.status.rawValue)
                bindOptionalText(stmt, index: 5, value: item.prep)
                bindText(stmt, index: 6, value: item.prepState.rawValue)
                sqlite3_bind_int64(stmt, 7, orderSeq)
                sqlite3_bind_double(stmt, 8, item.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 9, item.updatedAt.timeIntervalSince1970)

                if sqlite3_step(stmt) != SQLITE_DONE {
                    throw lastSQLiteError()
                }
            }

            return item
        }
    }

    public func getDock(lane: Lane? = nil) throws -> DockSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return try buildSnapshotUnlocked(lane: lane ?? currentActiveLane)
    }

    @discardableResult
    public func shift(to lane: Lane) throws -> DockSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return try inTransaction {
            try writeMetaUnlocked(key: "active_lane", value: lane.rawValue)
            currentActiveLane = lane
            return try buildSnapshotUnlocked(lane: lane)
        }
    }

    @discardableResult
    public func resolveBerth(id: String) throws -> ResolveResult {
        lock.lock()
        defer { lock.unlock() }

        return try inTransaction {
            guard let target = try fetchItemUnlocked(id: id) else {
                throw DockError.itemNotFound(id)
            }
            if target.status == .deep {
                return ResolveResult(sunkItem: target, promotedItem: nil)
            }

            let now = Date()
            try updateItemUnlocked(id: id, lane: target.lane, status: .deep, orderSeq: nil, updatedAt: now)
            guard let sunk = try fetchItemUnlocked(id: id) else {
                throw DockError.itemNotFound(id)
            }

            var promoted: DockItem? = nil
            if target.status == .docked {
                promoted = try promoteOldestQueuedUnlocked(in: target.lane, now: now)
            }
            return ResolveResult(sunkItem: sunk, promotedItem: promoted)
        }
    }

    @discardableResult
    public func reclassify(id: String, to target: ReclassifyTarget) throws -> DockItem {
        lock.lock()
        defer { lock.unlock() }

        return try inTransaction {
            guard let current = try fetchItemUnlocked(id: id) else {
                throw DockError.itemNotFound(id)
            }

            let now = Date()
            switch target {
            case .deep:
                if current.status == .deep {
                    return current
                }
                try updateItemUnlocked(id: id, lane: current.lane, status: .deep, orderSeq: nil, updatedAt: now)
                if current.status == .docked {
                    _ = try promoteOldestQueuedUnlocked(in: current.lane, now: now)
                }
                guard let updated = try fetchItemUnlocked(id: id) else {
                    throw DockError.itemNotFound(id)
                }
                return updated

            case .flipLane, .lane:
                let destLane: Lane
                switch target {
                case .flipLane:
                    destLane = current.lane.opposite
                case .lane(let explicitLane):
                    destLane = explicitLane
                case .deep:
                    destLane = current.lane
                }

                if current.lane == destLane && current.status != .deep {
                    return current
                }

                let dockedInDest = try countItems(lane: destLane, status: .docked)
                let newStatus: ItemStatus = dockedInDest < Self.maxBerths ? .docked : .queued
                let newOrderSeq = try nextOrderSeqUnlocked()

                try updateItemUnlocked(
                    id: id,
                    lane: destLane,
                    status: newStatus,
                    orderSeq: newOrderSeq,
                    updatedAt: now
                )

                if current.status == .docked && current.lane != destLane {
                    _ = try promoteOldestQueuedUnlocked(in: current.lane, now: now)
                }

                guard let updated = try fetchItemUnlocked(id: id) else {
                    throw DockError.itemNotFound(id)
                }
                return updated
            }
        }
    }

    public func deepItems(lane: Lane? = nil) throws -> [DockItem] {
        lock.lock()
        defer { lock.unlock() }

        if let lane {
            return try queryItems(
                sql: "SELECT id, raw, lane, status, prep, prep_state, created_at, updated_at FROM dock_items WHERE status = 'deep' AND lane = ?1 ORDER BY updated_at DESC, seq DESC;",
                binds: { stmt in
                    self.bindText(stmt, index: 1, value: lane.rawValue)
                }
            )
        }
        return try queryItems(
            sql: "SELECT id, raw, lane, status, prep, prep_state, created_at, updated_at FROM dock_items WHERE status = 'deep' ORDER BY updated_at DESC, seq DESC;"
        )
    }

    // MARK: - Internal SQLite Helpers

    private static let lifeSignals: [String] = [
        "下班", "周末", "车险", "续保", "买", "药", "娃", "孩子", "家", "老婆", "老公",
        "父母", "爸", "妈", "体检", "快递", "丰巢", "水电", "猫", "狗", "牙医", "超市",
        "做饭", "晚饭", "报名", "洗衣",
        "grocery", "groceries", "pharmacy", "dentist", "errand", "laundry", "dinner", "family", "pick up", "pickup"
    ]

    public static func inferLaneLocally(for raw: String) -> Lane {
        let lowered = raw.lowercased()
        for signal in lifeSignals where lowered.contains(signal) {
            return .life
        }
        return .work
    }

    private func readMetaUnlocked(key: String) throws -> String? {
        try withStatement("SELECT value FROM dock_meta WHERE key = ?1 LIMIT 1;") { stmt in
            bindText(stmt, index: 1, value: key)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                return columnText(stmt, 0)
            } else if rc == SQLITE_DONE {
                return nil
            } else {
                throw lastSQLiteError()
            }
        }
    }

    private func writeMetaUnlocked(key: String, value: String) throws {
        try withStatement("""
            INSERT INTO dock_meta (key, value) VALUES (?1, ?2)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """) { stmt in
            bindText(stmt, index: 1, value: key)
            bindText(stmt, index: 2, value: value)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw lastSQLiteError()
            }
        }
    }

    private func buildSnapshotUnlocked(lane targetLane: Lane) throws -> DockSnapshot {
        let berths = try queryItems(
            sql: "SELECT id, raw, lane, status, prep, prep_state, created_at, updated_at FROM dock_items WHERE lane = ?1 AND status = 'docked' ORDER BY order_seq ASC, seq ASC;",
            binds: { stmt in
                self.bindText(stmt, index: 1, value: targetLane.rawValue)
            }
        )
        let queuedCount = try countItems(lane: targetLane, status: .queued)
        let offstageCount =
            try countItems(lane: targetLane.opposite, status: .docked)
            + countItems(lane: targetLane.opposite, status: .queued)
        let deepCount = try countAllByStatus(.deep)

        return DockSnapshot(
            activeLane: currentActiveLane,
            lane: targetLane,
            berths: berths,
            queuedCount: queuedCount,
            offstageCount: offstageCount,
            deepCount: deepCount
        )
    }

    private func nextOrderSeqUnlocked() throws -> Int64 {
        try withStatement("SELECT COALESCE(MAX(order_seq), 0) + 1 FROM dock_items;") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw lastSQLiteError()
            }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private func countItems(lane: Lane, status: ItemStatus) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM dock_items WHERE lane = ?1 AND status = ?2;") { stmt in
            bindText(stmt, index: 1, value: lane.rawValue)
            bindText(stmt, index: 2, value: status.rawValue)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw lastSQLiteError()
            }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func countAllByStatus(_ status: ItemStatus) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM dock_items WHERE status = ?1;") { stmt in
            bindText(stmt, index: 1, value: status.rawValue)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw lastSQLiteError()
            }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func fetchItemUnlocked(id: String) throws -> DockItem? {
        let matches = try queryItems(
            sql: "SELECT id, raw, lane, status, prep, prep_state, created_at, updated_at FROM dock_items WHERE id = ?1 LIMIT 1;",
            binds: { stmt in
                self.bindText(stmt, index: 1, value: id)
            }
        )
        return matches.first
    }

    private func updateItemUnlocked(
        id: String,
        lane: Lane,
        status: ItemStatus,
        orderSeq: Int64?,
        updatedAt: Date
    ) throws {
        if let orderSeq {
            try withStatement("UPDATE dock_items SET lane = ?1, status = ?2, order_seq = ?3, updated_at = ?4 WHERE id = ?5;") { stmt in
                bindText(stmt, index: 1, value: lane.rawValue)
                bindText(stmt, index: 2, value: status.rawValue)
                sqlite3_bind_int64(stmt, 3, orderSeq)
                sqlite3_bind_double(stmt, 4, updatedAt.timeIntervalSince1970)
                bindText(stmt, index: 5, value: id)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    throw lastSQLiteError()
                }
            }
        } else {
            try withStatement("UPDATE dock_items SET lane = ?1, status = ?2, updated_at = ?3 WHERE id = ?4;") { stmt in
                bindText(stmt, index: 1, value: lane.rawValue)
                bindText(stmt, index: 2, value: status.rawValue)
                sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSince1970)
                bindText(stmt, index: 4, value: id)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    throw lastSQLiteError()
                }
            }
        }
    }

    private func promoteOldestQueuedUnlocked(in lane: Lane, now: Date) throws -> DockItem? {
        let dockedCount = try countItems(lane: lane, status: .docked)
        guard dockedCount < Self.maxBerths else { return nil }

        let nextQueued = try queryItems(
            sql: "SELECT id, raw, lane, status, prep, prep_state, created_at, updated_at FROM dock_items WHERE lane = ?1 AND status = 'queued' ORDER BY order_seq ASC, seq ASC LIMIT 1;",
            binds: { stmt in
                self.bindText(stmt, index: 1, value: lane.rawValue)
            }
        ).first

        guard let candidate = nextQueued else { return nil }
        let promotedOrderSeq = try nextOrderSeqUnlocked()
        try updateItemUnlocked(
            id: candidate.id,
            lane: lane,
            status: .docked,
            orderSeq: promotedOrderSeq,
            updatedAt: now
        )
        return try fetchItemUnlocked(id: candidate.id)
    }

    private func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "SQLite execution failed"
            if let errMsg { sqlite3_free(errMsg) }
            throw DockError.storageFailure(message)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw lastSQLiteError()
        }
        guard let stmt else {
            throw lastSQLiteError()
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func queryItems(sql: String, binds: (OpaquePointer) -> Void = { _ in }) throws -> [DockItem] {
        try withStatement(sql) { stmt in
            binds(stmt)
            var results: [DockItem] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    results.append(readItem(from: stmt))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw lastSQLiteError()
                }
            }
            return results
        }
    }

    private func readItem(from stmt: OpaquePointer) -> DockItem {
        let id = columnText(stmt, 0)
        let raw = columnText(stmt, 1)
        let lane = Lane(rawValue: columnText(stmt, 2)) ?? .work
        let status = ItemStatus(rawValue: columnText(stmt, 3)) ?? .docked
        let prep: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : columnText(stmt, 4)
        let prepState = PrepState(rawValue: columnText(stmt, 5)) ?? .pending
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        return DockItem(
            id: id,
            raw: raw,
            lane: lane,
            status: status,
            prep: prep,
            prepState: prepState,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            bindText(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func lastSQLiteError() -> DockError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
        return .storageFailure(message)
    }
}
