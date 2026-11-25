import Foundation
import MindDockCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String, file: String = #fileID, line: Int = #line) {
        self.description = "\(file):\(line) — \(message)"
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String = "",
    file: String = #fileID,
    line: Int = #line
) throws {
    if actual != expected {
        let suffix = message.isEmpty ? "" : " (\(message))"
        throw TestFailure("Expected \(expected), got \(actual)\(suffix)", file: file, line: line)
    }
}

func expectTrue(
    _ condition: Bool,
    _ message: String,
    file: String = #fileID,
    line: Int = #line
) throws {
    if !condition {
        throw TestFailure(message, file: file, line: line)
    }
}

func withTempDatabasePath<T>(_ body: (String) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindDockTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbPath = dir.appendingPathComponent("minddock.sqlite3").path
    return try body(dbPath)
}

struct TestCase: Sendable {
    let name: String
    let run: @Sendable () throws -> Void
}

let allTests: [TestCase] = [
    TestCase(name: "drop_docks_item_with_sacred_raw_text") {
        try withTempDatabasePath { dbPath in
            let engine = try DockEngine(databasePath: dbPath)
            let sacredRaw = "  排查支付回调偶发 504 超时 — keep exact spacing & symbols!  "
            let dropped = try engine.drop(sacredRaw, lane: .work)

            try expectEqual(dropped.raw, sacredRaw, "raw text must be preserved verbatim")
            try expectEqual(dropped.lane, .work)
            try expectEqual(dropped.status, .docked)

            let snapshot = try engine.getDock(lane: .work)
            try expectEqual(snapshot.berths.count, 1)
            try expectEqual(snapshot.berths[0].raw, sacredRaw)
            try expectEqual(snapshot.queuedCount, 0)
        }
    },
    TestCase(name: "three_berth_cap_queues_fourth_and_fifth_drops_offstage") {
        try withTempDatabasePath { dbPath in
            let engine = try DockEngine(databasePath: dbPath)
            let w1 = try engine.drop("Work 1: Passkey login spike", lane: .work)
            let w2 = try engine.drop("Work 2: Investigate 504 gateway timeout", lane: .work)
            let w3 = try engine.drop("Work 3: Add webhook rate limiter", lane: .work)
            let w4 = try engine.drop("Work 4: Write CONTRIBUTING guide", lane: .work)
            let w5 = try engine.drop("Work 5: Audit SQLite WAL checkpoints", lane: .work)

            try expectEqual(w1.status, .docked)
            try expectEqual(w2.status, .docked)
            try expectEqual(w3.status, .docked)
            try expectEqual(w4.status, .queued, "4th drop must enter off-stage queue")
            try expectEqual(w5.status, .queued, "5th drop must enter off-stage queue")

            let dock = try engine.getDock(lane: .work)
            try expectEqual(dock.berths.map(\.raw), [
                "Work 1: Passkey login spike",
                "Work 2: Investigate 504 gateway timeout",
                "Work 3: Add webhook rate limiter"
            ])
            try expectEqual(dock.queuedCount, 2)
        }
    },
    TestCase(name: "work_and_life_enforce_independent_three_berth_caps_and_shift") {
        try withTempDatabasePath { dbPath in
            let engine = try DockEngine(databasePath: dbPath)
            _ = try engine.drop("W1", lane: .work)
            _ = try engine.drop("W2", lane: .work)
            _ = try engine.drop("W3", lane: .work)
            _ = try engine.drop("W4", lane: .work)

            let l1 = try engine.drop("L1: 下班取快递", lane: .life)
            let l2 = try engine.drop("L2: 买退烧贴", lane: .life)
            let l3 = try engine.drop("L3: 周末车险续保", lane: .life)
            let l4 = try engine.drop("L4: 约牙医洗牙", lane: .life)

            try expectEqual(l1.status, .docked, "Life lane has its own 3-Berth budget")
            try expectEqual(l2.status, .docked)
            try expectEqual(l3.status, .docked)
            try expectEqual(l4.status, .queued)

            let workDock = try engine.getDock()
            try expectEqual(workDock.activeLane, .work)
            try expectEqual(workDock.lane, .work)
            try expectEqual(workDock.berths.map(\.raw), ["W1", "W2", "W3"])
            try expectEqual(workDock.queuedCount, 1)
            try expectEqual(workDock.offstageCount, 4, "4 active Life items wait off-stage")

            let lifeDock = try engine.shift(to: .life)
            try expectEqual(lifeDock.activeLane, .life)
            try expectEqual(lifeDock.lane, .life)
            try expectEqual(lifeDock.berths.map(\.raw), ["L1: 下班取快递", "L2: 买退烧贴", "L3: 周末车险续保"])
            try expectEqual(lifeDock.queuedCount, 1)
            try expectEqual(lifeDock.offstageCount, 4, "4 active Work items wait off-stage")

            let currentDock = try engine.getDock()
            try expectEqual(currentDock.activeLane, .life)
            try expectEqual(currentDock.lane, .life)
        }
    },
    TestCase(name: "resolving_berth_sinks_to_deep_with_untouched_raw_and_promotes_fifo_from_queue") {
        try withTempDatabasePath { dbPath in
            let engine = try DockEngine(databasePath: dbPath)
            let w1 = try engine.drop("W1: Passkey auth", lane: .work)
            let sacredW2 = "W2: Fix 504 timeout — exact raw text [do-not-touch]"
            let w2 = try engine.drop(sacredW2, lane: .work)
            let w3 = try engine.drop("W3: Webhook rate limit", lane: .work)
            let w4 = try engine.drop("W4: First queued item (oldest)", lane: .work)
            let w5 = try engine.drop("W5: Second queued item (newer)", lane: .work)
            let l1 = try engine.drop("L1: Unrelated life berth", lane: .life)
            _ = try engine.drop("L2", lane: .life)
            _ = try engine.drop("L3", lane: .life)
            _ = try engine.drop("L4: Queued life item", lane: .life)

            let firstResolve = try engine.resolveBerth(id: w2.id)
            try expectEqual(firstResolve.sunkItem.id, w2.id)
            try expectEqual(firstResolve.sunkItem.status, .deep)
            try expectEqual(firstResolve.sunkItem.raw, sacredW2, "Sacred raw text must remain untouched in Deep")
            try expectEqual(firstResolve.promotedItem?.id, w4.id, "Oldest queued Work item must promote first (FIFO)")
            try expectEqual(firstResolve.promotedItem?.status, .docked)

            let workDockAfterFirst = try engine.getDock(lane: .work)
            try expectEqual(workDockAfterFirst.berths.map(\.id), [w1.id, w3.id, w4.id])
            try expectEqual(workDockAfterFirst.queuedCount, 1)
            try expectEqual(workDockAfterFirst.deepCount, 1)

            // Life queue must be completely untouched by resolving a Work Berth
            let lifeDock = try engine.getDock(lane: .life)
            try expectEqual(lifeDock.berths.first?.id, l1.id)
            try expectEqual(lifeDock.queuedCount, 1)

            // Resolving another Work Berth promotes W5 (next in FIFO)
            let secondResolve = try engine.resolveBerth(id: w1.id)
            try expectEqual(secondResolve.promotedItem?.id, w5.id)

            // Resolving when queue is empty leaves 2 docked Berths and promotes nil
            let thirdResolve = try engine.resolveBerth(id: w3.id)
            try expectEqual(thirdResolve.promotedItem, nil)

            let finalWorkDock = try engine.getDock(lane: .work)
            try expectEqual(finalWorkDock.berths.map(\.id), [w4.id, w5.id])
            try expectEqual(finalWorkDock.queuedCount, 0)

            let deep = try engine.deepItems(lane: .work)
            try expectEqual(deep.count, 3)
            try expectTrue(deep.contains(where: { $0.id == w2.id && $0.raw == sacredW2 }), "Deep must retain exact raw text")
        }
    },
    TestCase(name: "reclassify_flips_lane_respecting_target_cap_or_sinks_to_deep_and_promotes_vacated_lane") {
        try withTempDatabasePath { dbPath in
            let engine = try DockEngine(databasePath: dbPath)
            let w1 = try engine.drop("W1: Misclassified grocery errand", lane: .work)
            let w2 = try engine.drop("W2: Real work task", lane: .work)
            let w3 = try engine.drop("W3: Pure reference memo to sink", lane: .work)
            let w4 = try engine.drop("W4: Queued work #1", lane: .work)
            let w5 = try engine.drop("W5: Queued work #2", lane: .work)

            // Flip W1 from Work -> Life when Life has space (< 3 Berths)
            let flippedToOpenLife = try engine.reclassify(id: w1.id, to: .flipLane)
            try expectEqual(flippedToOpenLife.lane, .life)
            try expectEqual(flippedToOpenLife.status, .docked)
            try expectEqual(flippedToOpenLife.raw, "W1: Misclassified grocery errand")

            // Vacating W1's Work Berth promotes W4 automatically
            let workAfterFlip = try engine.getDock(lane: .work)
            try expectEqual(workAfterFlip.berths.map(\.id), [w2.id, w3.id, w4.id])
            try expectEqual(workAfterFlip.queuedCount, 1)

            //Sink W3 straight to Deep in one click -> promotes W5 into Work Dock
            let sunkDirect = try engine.reclassify(id: w3.id, to: .deep)
            try expectEqual(sunkDirect.status, .deep)
            try expectEqual(sunkDirect.raw, "W3: Pure reference memo to sink")

            let workAfterSink = try engine.getDock(lane: .work)
            try expectEqual(workAfterSink.berths.map(\.id), [w2.id, w4.id, w5.id])
            try expectEqual(workAfterSink.queuedCount, 0)

            // Fill Life lane (already has W1; add L2, L3, and queued L4), then flip W2 -> Life
            let l2 = try engine.drop("L2", lane: .life)
            let l3 = try engine.drop("L3", lane: .life)
            let l4 = try engine.drop("L4: Already waiting in Life queue", lane: .life)

            let flippedToFullLife = try engine.reclassify(id: w2.id, to: .lane(.life))
            try expectEqual(flippedToFullLife.lane, .life)
            try expectEqual(flippedToFullLife.status, .queued, "Flipping into a full 3-Berth lane queues at tail")

            // Resolving L2 in Life must promote L4 first (FIFO), NOT the newly flipped W2!
            let lifeResolve = try engine.resolveBerth(id: l2.id)
            try expectEqual(lifeResolve.promotedItem?.id, l4.id, "Existing Life queue item promotes before newly flipped item")

            let lifeDock = try engine.getDock(lane: .life)
            try expectEqual(lifeDock.berths.map(\.id), [w1.id, l3.id, l4.id])
            try expectEqual(lifeDock.queuedCount, 1)
        }
    },
    TestCase(name: "sqlite_persistence_across_engine_reinstantiation_and_zero_friction_drop_routing") {
        try withTempDatabasePath { dbPath in
            let w1Id: String
            let w4Id: String
            let lifeAutoId: String

            do {
                let firstEngine = try DockEngine(databasePath: dbPath)

                // Empty/whitespace-only drop must be rejected
                var caughtEmpty = false
                do {
                    _ = try firstEngine.drop("   \n\t  ")
                } catch DockError.emptyDrop {
                    caughtEmpty = true
                }
                try expectTrue(caughtEmpty, "Blank drops must throw DockError.emptyDrop")

                // Zero-friction Drops (lane == nil) infer Life vs Work locally while keeping raw sacred
                let w1 = try firstEngine.drop("重构登录模块：调研 WebAuthn Passkey")
                try expectEqual(w1.lane, .work)
                w1Id = w1.id

                _ = try firstEngine.drop("W2: Check CI flake", lane: .work)
                _ = try firstEngine.drop("W3: Review PR #42", lane: .work)
                let w4 = try firstEngine.drop("W4: Queued across restart", lane: .work)
                w4Id = w4.id

                let lifeAuto = try firstEngine.drop("下班顺路去丰巢把生鲜快递取了")
                try expectEqual(lifeAuto.lane, .life, "Unclassified errand Drop should route to Life automatically")
                lifeAutoId = lifeAuto.id

                let sunk = try firstEngine.drop("Old resolved thought", lane: .work)
                _ = try firstEngine.resolveBerth(id: sunk.id) // queued item wasn't promoted since sunk was queued

                _ = try firstEngine.shift(to: .life)
            }

            // Re-instantiate a brand new DockEngine against the same SQLite file
            let reopenedEngine = try DockEngine(databasePath: dbPath)
            let activeSnapshot = try reopenedEngine.getDock()
            try expectEqual(activeSnapshot.activeLane, .life, "Active lane must persist across restarts")
            try expectEqual(activeSnapshot.berths.map(\.id), [lifeAutoId])

            let workBeforeResolve = try reopenedEngine.getDock(lane: .work)
            try expectEqual(workBeforeResolve.berths.count, 3)
            try expectEqual(workBeforeResolve.queuedCount, 1)

            // Resolving W1 after restart must promote W4 from the persisted FIFO queue
            let resolveAfterRestart = try reopenedEngine.resolveBerth(id: w1Id)
            try expectEqual(resolveAfterRestart.promotedItem?.id, w4Id)

            let deepAfterRestart = try reopenedEngine.deepItems()
            try expectEqual(deepAfterRestart.count, 2)
        }
    }
]

let filter = CommandLine.arguments.dropFirst().first
let selected = allTests.filter { test in
    guard let filter else { return true }
    return test.name.localizedCaseInsensitiveContains(filter)
}

if selected.isEmpty {
    fputs("No tests matched filter '\(filter ?? "")'\n", stderr)
    Foundation.exit(1)
}

var passed = 0
var failed = 0

for test in selected {
    do {
        try test.run()
        print("PASS \(test.name)")
        passed += 1
    } catch {
        fputs("FAIL \(test.name): \(error)\n", stderr)
        failed += 1
    }
}

print("\nSummary: \(passed) passed, \(failed) failed")
Foundation.exit(failed == 0 ? 0 : 1)
