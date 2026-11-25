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
    private var mobileBridge: (any MobileBridgeClient)?
    private var audioTranscriber: (any AudioTranscriber)?

    public init(
        databasePath: String,
        mobileBridge: (any MobileBridgeClient)? = nil,
        audioTranscriber: (any AudioTranscriber)? = nil
    ) throws {
        self.mobileBridge = mobileBridge
        self.audioTranscriber = audioTranscriber
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
            CREATE TABLE IF NOT EXISTS processed_bridge_messages (
                message_id TEXT PRIMARY KEY,
                processed_at REAL NOT NULL
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

    public func setMobileBridge(_ bridge: (any MobileBridgeClient)?) {
        lock.withLock {
            self.mobileBridge = bridge
        }
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
    public func attachPrep(id: String, prep: String?, state: PrepState = .ready) throws -> DockItem {
        lock.lock()
        defer { lock.unlock() }
        return try inTransaction {
            guard try fetchItemUnlocked(id: id) != nil else {
                throw DockError.itemNotFound(id)
            }
            let now = Date()
            try withStatement("UPDATE dock_items SET prep = ?1, prep_state = ?2, updated_at = ?3 WHERE id = ?4;") { stmt in
                bindOptionalText(stmt, index: 1, value: prep)
                bindText(stmt, index: 2, value: state.rawValue)
                sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
                bindText(stmt, index: 4, value: id)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    throw lastSQLiteError()
                }
            }
            guard let updated = try fetchItemUnlocked(id: id) else {
                throw DockError.itemNotFound(id)
            }
            return updated
        }
    }

    private static let lastLifePushFingerprintMetaKey = "last_life_push_fingerprint"
    private static let feishuSyncCursorMetaKey = "feishu_sync_cursor"

    @discardableResult
    public func shiftAndSync(to lane: Lane) async throws -> ShiftSyncResult {
        let snap = try shift(to: lane)
        if lane == .life {
            if snap.berths.isEmpty {
                try lock.withLock {
                    try inTransaction {
                        try writeMetaUnlocked(key: Self.lastLifePushFingerprintMetaKey, value: "")
                    }
                }
                return ShiftSyncResult(snapshot: snap, pushedLifeDock: false)
            }
            let (bridge, savedFingerprint) = try lock.withLock {
                (self.mobileBridge, try self.readMetaUnlocked(key: Self.lastLifePushFingerprintMetaKey))
            }
            guard let bridge else {
                return ShiftSyncResult(snapshot: snap, pushedLifeDock: false)
            }
            let berths = snap.berths.prefix(Self.maxBerths).enumerated().map { index, item in
                LifeDockPushBerth(
                    slotNumber: index + 1,
                    id: item.id,
                    raw: item.raw,
                    prep: item.prep
                )
            }
            let fingerprint = Self.computeLifePushFingerprint(berths: berths, queuedCount: snap.queuedCount)
            if savedFingerprint == fingerprint {
                return ShiftSyncResult(snapshot: snap, pushedLifeDock: false)
            }
            let payload = LifeDockPushPayload(
                berths: berths,
                queuedCount: snap.queuedCount,
                fingerprint: fingerprint
            )
            try await bridge.pushLifeDock(payload)
            try lock.withLock {
                try inTransaction {
                    try writeMetaUnlocked(key: Self.lastLifePushFingerprintMetaKey, value: fingerprint)
                }
            }
            return ShiftSyncResult(snapshot: snap, pushedLifeDock: true)
        } else {
            let report = try await syncMobileBridge()
            let updatedSnap = try getDock(lane: .work)
            return ShiftSyncResult(snapshot: updatedSnap, pushedLifeDock: false, syncReport: report)
        }
    }

    @discardableResult
    public func syncMobileBridge() async throws -> MobileSyncReport {
        let (bridge, transcriber, sinceCursor) = try lock.withLock {
            (self.mobileBridge, self.audioTranscriber, try self.readMetaUnlocked(key: Self.feishuSyncCursorMetaKey))
        }
        guard let bridge else {
            return MobileSyncReport(advancedCursor: sinceCursor)
        }

        let batch = try await bridge.pullMessages(sinceCursor: sinceCursor)
        let batchLifeBerths = try getDock(lane: .life).berths
        var resolvedItems: [ResolveResult] = []
        var droppedItems: [DockItem] = []

        for message in batch.messages {
            let alreadyProcessed = try lock.withLock {
                try isBridgeMessageProcessedUnlocked(messageId: message.messageId)
            }
            if alreadyProcessed {
                continue
            }

            if message.senderRole == .bot {
                try lock.withLock {
                    try markBridgeMessageProcessedUnlocked(messageId: message.messageId)
                }
                continue
            }

            var resolvedText = message.text
            if message.kind == .audio,
               resolvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let audioData = message.audioData,
               let transcriber {
                resolvedText = try await transcriber.transcribe(
                    audioData: audioData,
                    fileExtension: message.audioFileExtension ?? "opus"
                )
            }

            if resolvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try lock.withLock {
                    try markBridgeMessageProcessedUnlocked(messageId: message.messageId)
                }
                continue
            }

            if message.kind == .text, let slots = Self.parseCompletionSlots(from: resolvedText) {
                for slot in slots {
                    let idx = slot - 1
                    if idx >= 0 && idx < batchLifeBerths.count {
                        let targetId = batchLifeBerths[idx].id
                        let res = try resolveBerth(id: targetId)
                        resolvedItems.append(res)
                    }
                }
                try lock.withLock {
                    try markBridgeMessageProcessedUnlocked(messageId: message.messageId)
                }
                continue
            }

            let created = try drop(resolvedText, lane: nil)
            let prepNote = Self.buildLocalMobilePrep(for: created, kind: message.kind)
            let enriched = try attachPrep(id: created.id, prep: prepNote, state: .ready)
            droppedItems.append(enriched)

            try lock.withLock {
                try markBridgeMessageProcessedUnlocked(messageId: message.messageId)
            }
        }

        let finalCursor = batch.nextCursor ?? sinceCursor
        if let nextCursor = batch.nextCursor, nextCursor != sinceCursor {
            try lock.withLock {
                try inTransaction {
                    try writeMetaUnlocked(key: Self.feishuSyncCursorMetaKey, value: nextCursor)
                }
            }
        }

        return MobileSyncReport(
            resolvedItems: resolvedItems,
            droppedItems: droppedItems,
            advancedCursor: finalCursor
        )
    }

    public static func parseCompletionSlots(from raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns = [
            #"^([1-3](?:[\s,，、/]+[1-3])*)$"#,
            #"^(?:done|ok|resolve|complete|check|已完成|完成|搞定|已办|做好了|好了|✓|✅|☑)[\s:/#\-]*([1-3](?:[\s,，、/#]+[1-3])*)$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, options: [], range: nsRange),
               match.numberOfRanges >= 2,
               let groupRange = Range(match.range(at: 1), in: trimmed) {
                let digitsPart = String(trimmed[groupRange])
                var seen = Set<Int>()
                var result: [Int] = []
                for ch in digitsPart {
                    if let val = ch.wholeNumberValue, (1...Self.maxBerths).contains(val), !seen.contains(val) {
                        seen.insert(val)
                        result.append(val)
                    }
                }
                if !result.isEmpty {
                    return result
                }
            }
        }
        return nil
    }

    private static func buildLocalMobilePrep(for item: DockItem, kind: InboundMessageKind) -> String {
        let sourceTag = kind == .audio ? "飞书语音闪投（已转写）" : "飞书移动端闪投"
        let laneHint = item.lane == .work ? "已备料就绪，回到工位可直接推进" : "已归入生活泊位，离席时自动提醒"
        return "\(sourceTag) · \(laneHint)"
    }

    private func isBridgeMessageProcessedUnlocked(messageId: String) throws -> Bool {
        try withStatement("SELECT 1 FROM processed_bridge_messages WHERE message_id = ?1 LIMIT 1;") { stmt in
            bindText(stmt, index: 1, value: messageId)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                return true
            } else if rc == SQLITE_DONE {
                return false
            } else {
                throw lastSQLiteError()
            }
        }
    }

    private func markBridgeMessageProcessedUnlocked(messageId: String) throws {
        try withStatement("""
            INSERT INTO processed_bridge_messages (message_id, processed_at)
            VALUES (?1, ?2)
            ON CONFLICT(message_id) DO NOTHING;
            """) { stmt in
            bindText(stmt, index: 1, value: messageId)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw lastSQLiteError()
            }
        }
    }

    private static func computeLifePushFingerprint(berths: [LifeDockPushBerth], queuedCount: Int) -> String {
        let parts = berths.map { b in
            "\(b.slotNumber)|\(b.id)|\(b.raw)|\(b.prep ?? "")"
        }.joined(separator: "\n")
        return "q=\(queuedCount)\n\(parts)"
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
