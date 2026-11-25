import AVFoundation
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

func expectUnwrap<T>(
    _ value: T?,
    _ message: String,
    file: String = #fileID,
    line: Int = #line
) throws -> T {
    guard let value else {
        throw TestFailure(message, file: file, line: line)
    }
    return value
}

func withTempDatabasePath<T>(_ body: (String) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindDockTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbPath = dir.appendingPathComponent("minddock.sqlite3").path
    return try body(dbPath)
}

func withTempDatabasePathAsync<T>(_ body: (String) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindDockTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbPath = dir.appendingPathComponent("minddock.sqlite3").path
    return try await body(dbPath)
}

struct TestCase: Sendable {
    let name: String
    let run: @Sendable () throws -> Void
}

func runAsyncTest(_ block: @escaping @Sendable () async throws -> Void) throws {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        private var finished = false
        var result: Result<Void, Error>?

        var isDone: Bool {
            lock.withLock { finished }
        }

        func complete(_ value: Result<Void, Error>) {
            lock.withLock {
                result = value
                finished = true
            }
        }
    }
    let box = Box()
    Task.detached {
        do {
            try await block()
            box.complete(.success(()))
        } catch {
            box.complete(.failure(error))
        }
    }
    while !box.isDone {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
    }
    if case .failure(let error) = box.result {
        throw error
    }
}

struct CapturedHTTPRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        for (k, v) in headers where k.caseInsensitiveCompare(name) == .orderedSame {
            return v
        }
        return nil
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private final class StateBox: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (CapturedHTTPRequest) throws -> (Int, [String: String], Data))?
        var capturedRequests: [CapturedHTTPRequest] = []
    }
    private static let state = StateBox()

    static func install(
        _ newHandler: @escaping @Sendable (CapturedHTTPRequest) throws -> (Int, [String: String], Data)
    ) {
        state.lock.withLock {
            state.capturedRequests = []
            state.handler = newHandler
        }
    }

    static func requests() -> [CapturedHTTPRequest] {
        state.lock.withLock { state.capturedRequests }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func makeSession(
        handler: @escaping @Sendable (CapturedHTTPRequest) throws -> (Int, [String: String], Data)
    ) -> URLSession {
        install(handler)
        return makeSession()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let readCount = stream.read(&buffer, maxLength: buffer.count)
                if readCount > 0 {
                    bodyData.append(buffer, count: readCount)
                } else {
                    break
                }
            }
        }

        let captured = CapturedHTTPRequest(
            method: request.httpMethod ?? "GET",
            url: request.url ?? URL(string: "https://invalid.local")!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: bodyData
        )

        let activeHandler = Self.state.lock.withLock { () -> (@Sendable (CapturedHTTPRequest) throws -> (Int, [String: String], Data))? in
            Self.state.capturedRequests.append(captured)
            return Self.state.handler
        }

        guard let activeHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (statusCode, headers, responseBody) = try activeHandler(captured)
            let response = HTTPURLResponse(
                url: captured.url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

struct StubPrepIntelligence: IntelligenceClient {
    var prepBySubstring: [String: String] = [:]
    var defaultPrep: String? = nil

    func prepareDrop(raw: String, explicitLane: Lane?) async -> DropPrepAnalysis {
        let lane = explicitLane ?? DockEngine.inferLaneLocally(for: raw)
        for (needle, prep) in prepBySubstring where raw.contains(needle) {
            return DropPrepAnalysis(lane: lane, prep: prep, prepState: .ready)
        }
        if let defaultPrep {
            return DropPrepAnalysis(lane: lane, prep: defaultPrep, prepState: .ready)
        }
        return DropPrepAnalysis(lane: lane, prep: nil, prepState: .skipped)
    }
}

final class FakeMobileBridgeClient: MobileBridgeClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var pushedPayloads: [LifeDockPushPayload] = []
    private(set) var pullCursorsReceived: [String?] = []
    var queuedBatches: [InboundMessageBatch] = []
    var failNextPushError: Error?

    func pushLifeDock(_ payload: LifeDockPushPayload) async throws {
        try lock.withLock {
            if let err = failNextPushError {
                failNextPushError = nil
                throw err
            }
            pushedPayloads.append(payload)
        }
    }

    func pullMessages(sinceCursor: String?) async throws -> InboundMessageBatch {
        lock.withLock {
            pullCursorsReceived.append(sinceCursor)
            if !queuedBatches.isEmpty {
                return queuedBatches.removeFirst()
            }
            return InboundMessageBatch(messages: [], nextCursor: sinceCursor)
        }
    }
}

final class FakeAudioTranscriber: AudioTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var receivedClips: [(Data, String)] = []
    var stubbedTranscript: String

    init(stubbedTranscript: String) {
        self.stubbedTranscript = stubbedTranscript
    }

    func transcribe(audioData: Data, fileExtension: String) async throws -> String {
        lock.withLock {
            receivedClips.append((audioData, fileExtension))
            return stubbedTranscript
        }
    }
}

func writeSampleSineCAF(to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frameCount: AVAudioFrameCount = 4_410
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    if let channel = buffer.floatChannelData?[0] {
        for i in 0..<Int(frameCount) {
            channel[i] = sin(Float(i) * 0.08) * 0.25
        }
    }
    try file.write(from: buffer)
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

            let lifeDock = try engine.getDock(lane: .life)
            try expectEqual(lifeDock.berths.first?.id, l1.id)
            try expectEqual(lifeDock.queuedCount, 1)

            let secondResolve = try engine.resolveBerth(id: w1.id)
            try expectEqual(secondResolve.promotedItem?.id, w5.id)

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

            let flippedToOpenLife = try engine.reclassify(id: w1.id, to: .flipLane)
            try expectEqual(flippedToOpenLife.lane, .life)
            try expectEqual(flippedToOpenLife.status, .docked)
            try expectEqual(flippedToOpenLife.raw, "W1: Misclassified grocery errand")

            let workAfterFlip = try engine.getDock(lane: .work)
            try expectEqual(workAfterFlip.berths.map(\.id), [w2.id, w3.id, w4.id])
            try expectEqual(workAfterFlip.queuedCount, 1)

            let sunkDirect = try engine.reclassify(id: w3.id, to: .deep)
            try expectEqual(sunkDirect.status, .deep)
            try expectEqual(sunkDirect.raw, "W3: Pure reference memo to sink")

            let workAfterSink = try engine.getDock(lane: .work)
            try expectEqual(workAfterSink.berths.map(\.id), [w2.id, w4.id, w5.id])
            try expectEqual(workAfterSink.queuedCount, 0)

            let l2 = try engine.drop("L2", lane: .life)
            let l3 = try engine.drop("L3", lane: .life)
            let l4 = try engine.drop("L4: Already waiting in Life queue", lane: .life)

            let flippedToFullLife = try engine.reclassify(id: w2.id, to: .lane(.life))
            try expectEqual(flippedToFullLife.lane, .life)
            try expectEqual(flippedToFullLife.status, .queued, "Flipping into a full 3-Berth lane queues at tail")

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

                var caughtEmpty = false
                do {
                    _ = try firstEngine.drop("   \n\t  ")
                } catch DockError.emptyDrop {
                    caughtEmpty = true
                }
                try expectTrue(caughtEmpty, "Blank drops must throw DockError.emptyDrop")

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
                _ = try firstEngine.resolveBerth(id: sunk.id)

                _ = try firstEngine.shift(to: .life)
            }

            let reopenedEngine = try DockEngine(databasePath: dbPath)
            let activeSnapshot = try reopenedEngine.getDock()
            try expectEqual(activeSnapshot.activeLane, .life, "Active lane must persist across restarts")
            try expectEqual(activeSnapshot.berths.map(\.id), [lifeAutoId])

            let workBeforeResolve = try reopenedEngine.getDock(lane: .work)
            try expectEqual(workBeforeResolve.berths.count, 3)
            try expectEqual(workBeforeResolve.queuedCount, 1)

            let resolveAfterRestart = try reopenedEngine.resolveBerth(id: w1Id)
            try expectEqual(resolveAfterRestart.promotedItem?.id, w4Id)

            let deepAfterRestart = try reopenedEngine.deepItems()
            try expectEqual(deepAfterRestart.count, 2)
        }
    },
    TestCase(name: "departure_shift_to_life_pushes_numbered_berths_with_prep_notes_and_skips_when_empty") {
        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let bridge = FakeMobileBridgeClient()
                let intelligence = StubPrepIntelligence(prepBySubstring: [
                    "丰巢": "取件码检查短信；生鲜需 21:00 前拿回冰箱",
                    "退烧贴": "24h 药店就在小区南门"
                ])
                let engine = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: intelligence,
                    mobileBridge: bridge
                )

                let emptyShift = try await engine.shiftAndSync(to: .life)
                try expectEqual(emptyShift.snapshot.activeLane, .life)
                try expectEqual(emptyShift.pushedLifeDock, false)
                try expectEqual(bridge.pushedPayloads.count, 0)

                _ = try engine.shift(to: .work)
                let sacredL1 = "下班去丰巢取冷链快递 #A92"
                let l1 = try engine.drop(sacredL1, lane: .life)
                let l2 = try engine.drop("买儿童退烧贴", lane: .life)
                let l3 = try engine.drop("周末车险续保比价", lane: .life)
                let l4 = try engine.drop("预约洗牙（排队的第 4 项）", lane: .life)

                let preppedL1 = try await engine.awaitPrep(id: l1.id)
                try expectEqual(preppedL1.raw, sacredL1, "Prep must never mutate raw text")
                try expectEqual(preppedL1.prep, "取件码检查短信；生鲜需 21:00 前拿回冰箱")
                try expectEqual(preppedL1.prepState, .ready)
                _ = try await engine.awaitPrep(id: l2.id)
                _ = try await engine.awaitPrep(id: l3.id)
                _ = try await engine.awaitPrep(id: l4.id)

                let departure = try await engine.shiftAndSync(to: .life)
                try expectEqual(departure.snapshot.activeLane, .life)
                try expectEqual(departure.pushedLifeDock, true)
                try expectEqual(bridge.pushedPayloads.count, 1)

                let payload = bridge.pushedPayloads[0]
                try expectEqual(payload.queuedCount, 1)
                try expectEqual(payload.berths, [
                    LifeDockPushBerth(
                        slotNumber: 1,
                        id: l1.id,
                        raw: sacredL1,
                        prep: "取件码检查短信；生鲜需 21:00 前拿回冰箱"
                    ),
                    LifeDockPushBerth(
                        slotNumber: 2,
                        id: l2.id,
                        raw: "买儿童退烧贴",
                        prep: "24h 药店就在小区南门"
                    ),
                    LifeDockPushBerth(
                        slotNumber: 3,
                        id: l3.id,
                        raw: "周末车险续保比价",
                        prep: nil
                    )
                ])
            }
        }
    },
    TestCase(name: "departure_shift_deduplicates_unchanged_life_dock_across_repeated_locks_and_restarts") {
        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let bridge = FakeMobileBridgeClient()
                do {
                    let engine = try DockEngine(databasePath: dbPath, mobileBridge: bridge)
                    let l1 = try engine.drop("下班买牛奶", lane: .life)
                    _ = try await engine.awaitPrep(id: l1.id)

                    bridge.failNextPushError = URLError(.notConnectedToInternet)
                    var threwOnTransient = false
                    do {
                        _ = try await engine.shiftAndSync(to: .life)
                    } catch {
                        threwOnTransient = true
                    }
                    try expectTrue(threwOnTransient, "Transient push error should propagate")
                    try expectEqual(bridge.pushedPayloads.count, 0)

                    let firstPush = try await engine.shiftAndSync(to: .life)
                    try expectEqual(firstPush.pushedLifeDock, true)
                    try expectEqual(bridge.pushedPayloads.count, 1)

                    let duplicateSleep = try await engine.shiftAndSync(to: .life)
                    try expectEqual(duplicateSleep.pushedLifeDock, false)
                    try expectEqual(bridge.pushedPayloads.count, 1)
                }

                let reopened = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: StubPrepIntelligence(prepBySubstring: ["酸奶": "盒马低糖希腊酸奶"]),
                    mobileBridge: bridge
                )
                let afterRestart = try await reopened.shiftAndSync(to: .life)
                try expectEqual(afterRestart.pushedLifeDock, false, "Persisted SQLite fingerprint must prevent duplicate push after restart")
                try expectEqual(bridge.pushedPayloads.count, 1)

                let l2 = try reopened.drop("顺便买一盒酸奶", lane: .life)
                _ = try await reopened.awaitPrep(id: l2.id)
                let afterDockChange = try await reopened.shiftAndSync(to: .life)
                try expectEqual(afterDockChange.pushedLifeDock, true)
                try expectEqual(bridge.pushedPayloads.count, 2)
                try expectEqual(bridge.pushedPayloads[1].berths[1].prep, "盒马低糖希腊酸奶")
            }
        }
    },
    TestCase(name: "arrival_shift_pulls_unread_messages_ignores_bot_echoes_advances_cursor_and_docks_drops_with_prep") {
        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let bridge = FakeMobileBridgeClient()
                let intelligence = StubPrepIntelligence(defaultPrep: "1. Review reproduction steps\n2. Verify fix locally")
                let sacredWorkDrop = "  明早先排查 webhook 幂等锁偶发死锁问题  "
                bridge.queuedBatches = [
                    InboundMessageBatch(
                        messages: [
                            InboundMobileMessage(
                                messageId: "om_bot_card_1",
                                senderRole: .bot,
                                kind: .text,
                                text: "MindDock Life Dock: 1. 下班买牛奶",
                                createdAtTimestamp: "1732520000100"
                            ),
                            InboundMobileMessage(
                                messageId: "om_user_1",
                                senderRole: .user,
                                kind: .text,
                                text: sacredWorkDrop,
                                createdAtTimestamp: "1732520001500"
                            ),
                            InboundMobileMessage(
                                messageId: "om_user_2",
                                senderRole: .user,
                                kind: .text,
                                text: "周末带爸妈去医院拿体检报告",
                                createdAtTimestamp: "1732520002800"
                            )
                        ],
                        nextCursor: "1732520002800#om_user_2"
                    ),
                    InboundMessageBatch(
                        messages: [
                            InboundMobileMessage(
                                messageId: "om_user_2",
                                senderRole: .user,
                                kind: .text,
                                text: "周末带爸妈去医院拿体检报告",
                                createdAtTimestamp: "1732520002800"
                            ),
                            InboundMobileMessage(
                                messageId: "om_user_3",
                                senderRole: .user,
                                kind: .text,
                                text: "补齐 SQLite busy_timeout 配置",
                                createdAtTimestamp: "1732520009000"
                            )
                        ],
                        nextCursor: "1732520009000#om_user_3"
                    )
                ]

                do {
                    let engine = try DockEngine(
                        databasePath: dbPath,
                        intelligenceClient: intelligence,
                        mobileBridge: bridge
                    )
                    _ = try engine.shift(to: .life)

                    let arrival = try await engine.shiftAndSync(to: .work)
                    try expectEqual(arrival.snapshot.activeLane, .work)
                    try expectEqual(arrival.pushedLifeDock, false)
                    try expectEqual(bridge.pullCursorsReceived, [nil])
                    try expectEqual(arrival.syncReport?.droppedItems.count, 2)
                    try expectEqual(arrival.syncReport?.advancedCursor, "1732520002800#om_user_2")

                    try expectEqual(arrival.snapshot.berths.count, 1)
                    try expectEqual(arrival.snapshot.berths[0].raw, sacredWorkDrop)
                    try expectEqual(arrival.snapshot.berths[0].prepState, .ready)
                    try expectEqual(
                        arrival.snapshot.berths[0].prep,
                        "1. Review reproduction steps\n2. Verify fix locally"
                    )

                    let lifeDock = try engine.getDock(lane: .life)
                    try expectEqual(lifeDock.berths.map(\.raw), ["周末带爸妈去医院拿体检报告"])
                    try expectEqual(lifeDock.berths[0].prepState, .ready)
                }

                let reopened = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: intelligence,
                    mobileBridge: bridge
                )
                let secondSync = try await reopened.syncMobileBridge()
                try expectEqual(bridge.pullCursorsReceived, [nil, "1732520002800#om_user_2"])
                try expectEqual(secondSync.droppedItems.map(\.raw), ["补齐 SQLite busy_timeout 配置"])
                try expectEqual(secondSync.advancedCursor, "1732520009000#om_user_3")

                let workDock = try reopened.getDock(lane: .work)
                try expectEqual(workDock.berths.map(\.raw), [sacredWorkDrop, "补齐 SQLite busy_timeout 配置"])
            }
        }
    },
    TestCase(name: "inbound_sync_executes_quick_completion_replies_and_transcribes_audio_drops") {
        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let bridge = FakeMobileBridgeClient()
                let transcriber = FakeAudioTranscriber(stubbedTranscript: "下班顺便去药店买创可贴")
                let intelligence = StubPrepIntelligence(defaultPrep: "Prepared next step")
                let engine = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: intelligence,
                    mobileBridge: bridge,
                    audioTranscriber: transcriber
                )

                let l1 = try engine.drop("L1: 取丰巢生鲜快递", lane: .life)
                let l2 = try engine.drop("L2: 买儿童退烧贴", lane: .life)
                let l3 = try engine.drop("L3: 周末车险续保", lane: .life)
                let l4 = try engine.drop("L4: 预约牙医洗牙（候补队列）", lane: .life)
                _ = try await engine.awaitPrep(id: l1.id)
                _ = try await engine.awaitPrep(id: l2.id)
                _ = try await engine.awaitPrep(id: l3.id)
                _ = try await engine.awaitPrep(id: l4.id)

                _ = try await engine.shiftAndSync(to: .life)

                let fakeOpusBytes = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02])
                bridge.queuedBatches = [
                    InboundMessageBatch(
                        messages: [
                            InboundMobileMessage(
                                messageId: "om_reply_1",
                                senderRole: .user,
                                kind: .text,
                                text: "done 1",
                                createdAtTimestamp: "1732530001000"
                            ),
                            InboundMobileMessage(
                                messageId: "om_reply_2",
                                senderRole: .user,
                                kind: .text,
                                text: "搞定 2",
                                createdAtTimestamp: "1732530002000"
                            ),
                            InboundMobileMessage(
                                messageId: "om_real_work_sentence",
                                senderRole: .user,
                                kind: .text,
                                text: "明天完成 1 号接口压测报告",
                                createdAtTimestamp: "1732530003000"
                            ),
                            InboundMobileMessage(
                                messageId: "om_voice_1",
                                senderRole: .user,
                                kind: .audio,
                                text: "",
                                audioData: fakeOpusBytes,
                                audioFileExtension: "opus",
                                createdAtTimestamp: "1732530004000"
                            )
                        ],
                        nextCursor: "1732530004000#om_voice_1"
                    )
                ]

                let arrival = try await engine.shiftAndSync(to: .work)
                let report = try expectUnwrap(arrival.syncReport, "Expected syncReport on arrival")

                try expectEqual(report.resolvedItems.map(\.sunkItem.id), [l1.id, l2.id])
                try expectEqual(report.resolvedItems[0].promotedItem?.id, l4.id)

                try expectEqual(arrival.snapshot.berths.map(\.raw), ["明天完成 1 号接口压测报告"])

                try expectEqual(transcriber.receivedClips.count, 1)
                try expectEqual(transcriber.receivedClips[0].0, fakeOpusBytes)
                try expectEqual(transcriber.receivedClips[0].1, "opus")

                let lifeDock = try engine.getDock(lane: .life)
                try expectEqual(lifeDock.berths.map(\.raw), [
                    "L3: 周末车险续保",
                    "L4: 预约牙医洗牙（候补队列）",
                    "下班顺便去药店买创可贴"
                ])
                try expectEqual(lifeDock.berths[2].prepState, .ready)

                let deepLife = try engine.deepItems(lane: .life)
                try expectEqual(Set(deepLife.map(\.id)), Set([l1.id, l2.id]))
            }
        }
    },
    TestCase(name: "feishu_bridge_formats_lock_screen_payload_for_webhook_serverchan_generic_and_app_bot_rest") {
        try runAsyncTest {
            let samplePayload = LifeDockPushPayload(
                berths: [
                    LifeDockPushBerth(
                        slotNumber: 1,
                        id: "b1",
                        raw: "下班去丰巢取冷链快递",
                        prep: "取件码 8821，21:00 前回家"
                    ),
                    LifeDockPushBerth(
                        slotNumber: 2,
                        id: "b2",
                        raw: "买儿童退烧贴",
                        prep: nil
                    )
                ],
                queuedCount: 1,
                fingerprint: "fp-demo-1"
            )

            // 1. Outbound 1-line Feishu Custom Bot Webhook
            let webhookClient = FeishuMobileBridgeClient(
                config: MobileBridgeConfig(
                    webhookURL: URL(string: "https://open.feishu.cn/open-apis/bot/v2/hook/test-hook-token")!
                ),
                session: StubURLProtocol.makeSession { _ in
                    (200, ["Content-Type": "application/json"], Data(#"{"code":0,"msg":"success"}"#.utf8))
                }
            )
            try await webhookClient.pushLifeDock(samplePayload)

            let webhookReqs = StubURLProtocol.requests()
            try expectEqual(webhookReqs.count, 1)
            try expectEqual(webhookReqs[0].method, "POST")
            try expectEqual(webhookReqs[0].url.path, "/open-apis/bot/v2/hook/test-hook-token")
            let webhookJSON = try expectUnwrap(
                try JSONSerialization.jsonObject(with: webhookReqs[0].body) as? [String: Any],
                "Webhook body must be JSON object"
            )
            try expectEqual(webhookJSON["msg_type"] as? String, "interactive")
            let webhookBodyText = String(data: webhookReqs[0].body, encoding: .utf8) ?? ""
            try expectTrue(webhookBodyText.contains("1."), "Notification must number Berth 1")
            try expectTrue(webhookBodyText.contains("下班去丰巢取冷链快递"), "Notification must include Berth 1 raw")
            try expectTrue(webhookBodyText.contains("取件码 8821"), "Notification must include Berth 1 Prep note")
            try expectTrue(webhookBodyText.contains("2."), "Notification must number Berth 2")
            try expectTrue(webhookBodyText.contains("done 1"), "Notification must instruct quick completion reply")

            // 1b. Outbound 1-line ServerChan Webhook
            let serverChanClient = FeishuMobileBridgeClient(
                config: MobileBridgeConfig(
                    webhookURL: URL(string: "https://sctapi.ftqq.com/SCT123456.send")!
                ),
                session: StubURLProtocol.makeSession { _ in
                    (200, ["Content-Type": "application/json"], Data(#"{"code":0,"message":"success"}"#.utf8))
                }
            )
            try await serverChanClient.pushLifeDock(samplePayload)
            let scReqs = StubURLProtocol.requests()
            try expectEqual(scReqs.count, 1)
            let scJSON = try expectUnwrap(
                try JSONSerialization.jsonObject(with: scReqs[0].body) as? [String: Any],
                "ServerChan body must be JSON"
            )
            try expectTrue((scJSON["title"] as? String)?.contains("MindDock") == true, "ServerChan requires title")
            try expectTrue((scJSON["desp"] as? String)?.contains("下班去丰巢取冷链快递") == true, "ServerChan requires desp markdown")

            // 1c. Outbound generic JSON Webhook
            let genericWebhookClient = FeishuMobileBridgeClient(
                config: MobileBridgeConfig(
                    webhookURL: URL(string: "https://hooks.example.org/minddock-life")!
                ),
                session: StubURLProtocol.makeSession { _ in
                    (200, ["Content-Type": "application/json"], Data(#"{"ok":true}"#.utf8))
                }
            )
            try await genericWebhookClient.pushLifeDock(samplePayload)
            let genericReqs = StubURLProtocol.requests()
            try expectEqual(genericReqs.count, 1)
            let genericJSON = try expectUnwrap(
                try JSONSerialization.jsonObject(with: genericReqs[0].body) as? [String: Any],
                "Generic webhook body must be JSON"
            )
            try expectTrue(
                (genericJSON["text"] as? String)?.contains("下班去丰巢取冷链快递") == true,
                "Generic webhook payload must include Berth raw text"
            )

            // 2. Bidirectional Feishu App Bot REST (tenant_access_token + im/v1/messages) with token caching
            let appBotClient = FeishuMobileBridgeClient(
                config: MobileBridgeConfig(
                    appId: "cli_test_app",
                    appSecret: "sec_test_secret",
                    chatId: "oc_user_dm_chat"
                ),
                session: StubURLProtocol.makeSession { req in
                    if req.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
                        let body = #"{"code":0,"msg":"ok","tenant_access_token":"t-feishu-secret-token","expire":7200}"#
                        return (200, ["Content-Type": "application/json"], Data(body.utf8))
                    }
                    if req.url.path == "/open-apis/im/v1/messages" && req.method == "POST" {
                        let body = #"{"code":0,"msg":"success","data":{"message_id":"om_sent_card_1"}}"#
                        return (200, ["Content-Type": "application/json"], Data(body.utf8))
                    }
                    return (404, [:], Data())
                }
            )
            try await appBotClient.pushLifeDock(samplePayload)
            try await appBotClient.pushLifeDock(samplePayload)

            let botReqs = StubURLProtocol.requests()
            try expectEqual(botReqs.count, 3, "Expected 1 auth call + 2 message send calls (token cached)")
            try expectEqual(botReqs[0].url.path, "/open-apis/auth/v3/tenant_access_token/internal")
            let authBody = try expectUnwrap(
                try JSONSerialization.jsonObject(with: botReqs[0].body) as? [String: String],
                "Auth body must be JSON"
            )
            try expectEqual(authBody["app_id"], "cli_test_app")
            try expectEqual(authBody["app_secret"], "sec_test_secret")

            try expectEqual(botReqs[1].url.path, "/open-apis/im/v1/messages")
            try expectEqual(botReqs[1].url.query, "receive_id_type=chat_id")
            try expectEqual(botReqs[1].header("Authorization"), "Bearer t-feishu-secret-token")

            let sendBody = try expectUnwrap(
                try JSONSerialization.jsonObject(with: botReqs[1].body) as? [String: Any],
                "im/v1/messages body must be JSON"
            )
            try expectEqual(sendBody["receive_id"] as? String, "oc_user_dm_chat")
            try expectEqual(sendBody["msg_type"] as? String, "interactive")
            let contentString = try expectUnwrap(
                sendBody["content"] as? String,
                "Feishu im/v1/messages requires interactive content JSON string"
            )
            let parsedCard = try expectUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentString.utf8)) as? [String: Any],
                "Interactive content string must decode to valid JSON object"
            )
            try expectTrue(parsedCard["header"] != nil && parsedCard["elements"] != nil, "Interactive message must contain header and elements")
            try expectTrue(contentString.contains("取件码 8821"), "Encoded message must include Prep note")
        }
    },
    TestCase(name: "feishu_bridge_pulls_messages_with_cursor_downloads_audio_resource_and_transcribes") {
        try runAsyncTest {
            let expectedAudioBytes = Data([0x4F, 0x67, 0x67, 0x53, 0xAA, 0xBB, 0xCC])
            let transcriber = FakeAudioTranscriber(stubbedTranscript: "回程地铁上想到把周报发给总监")

            let webhookOnly = FeishuMobileBridgeClient(
                config: MobileBridgeConfig(webhookURL: URL(string: "https://open.feishu.cn/open-apis/bot/v2/hook/x")!),
                session: StubURLProtocol.makeSession()
            )
            let noopBatch = try await webhookOnly.pullMessages(sinceCursor: "cursor-0")
            try expectEqual(noopBatch.messages, [])
            try expectEqual(noopBatch.nextCursor, "cursor-0")

            let session = StubURLProtocol.makeSession { req in
                if req.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
                    let body = #"{"code":0,"msg":"ok","tenant_access_token":"t-pull-token","expire":7200}"#
                    return (200, ["Content-Type": "application/json"], Data(body.utf8))
                }
                if req.url.path == "/open-apis/im/v1/messages" && req.method == "GET" {
                    let comps = URLComponents(url: req.url, resolvingAgainstBaseURL: false)
                    let startTime = comps?.queryItems?.first(where: { $0.name == "start_time" })?.value
                    if startTime == "1732536410" {
                        let listJSON = """
                        {
                          "code": 0,
                          "msg": "success",
                          "data": {
                            "has_more": false,
                            "items": [
                              {
                                "message_id": "om_bot_echo_1",
                                "msg_type": "interactive",
                                "create_time": "1732540005100",
                                "sender": { "id": "cli_test", "sender_type": "app" },
                                "body": { "content": "{\\"title\\":\\"MindDock\\"}" }
                              },
                              {
                                "message_id": "om_user_text_1",
                                "msg_type": "text",
                                "create_time": "1732540005200",
                                "sender": { "id": "ou_user", "sender_type": "user" },
                                "body": { "content": "{\\"text\\":\\"done 1\\"}" }
                              },
                              {
                                "message_id": "om_user_audio_1",
                                "msg_type": "audio",
                                "create_time": "1732540005400",
                                "sender": { "id": "ou_user", "sender_type": "user" },
                                "body": { "content": "{\\"file_key\\":\\"file_v3_opus_99\\",\\"duration\\":3100}" }
                              }
                            ]
                          }
                        }
                        """
                        return (200, ["Content-Type": "application/json"], Data(listJSON.utf8))
                    } else if startTime == "1732540005" {
                        let listJSON = """
                        {
                          "code": 0,
                          "msg": "success",
                          "data": {
                            "has_more": false,
                            "items": [
                              {
                                "message_id": "om_user_audio_1",
                                "msg_type": "audio",
                                "create_time": "1732540005400",
                                "sender": { "id": "ou_user", "sender_type": "user" },
                                "body": { "content": "{\\"file_key\\":\\"file_v3_opus_99\\"}" }
                              },
                              {
                                "message_id": "om_user_text_2",
                                "msg_type": "text",
                                "create_time": "1732540005950",
                                "sender": { "id": "ou_user", "sender_type": "user" },
                                "body": { "content": "{\\"text\\":\\"到家记得给猫换水\\"}" }
                              }
                            ]
                          }
                        }
                        """
                        return (200, ["Content-Type": "application/json"], Data(listJSON.utf8))
                    }
                }
                if req.url.path == "/open-apis/im/v1/messages/om_user_audio_1/resources/file_v3_opus_99" {
                    return (200, ["Content-Type": "application/octet-stream"], expectedAudioBytes)
                }
                return (404, [:], Data())
            }

            let botClient = FeishuMobileBridgeClient(
                config: MobileBridgeConfig(
                    appId: "cli_test",
                    appSecret: "sec_test",
                    chatId: "oc_dm_99"
                ),
                session: session,
                audioTranscriber: transcriber,
                initialLookbackSeconds: 3600,
                now: { Date(timeIntervalSince1970: 1_732_540_010) }
            )

            let firstBatch = try await botClient.pullMessages(sinceCursor: nil)
            try expectEqual(firstBatch.nextCursor, "1732540005400#om_user_audio_1")
            try expectEqual(firstBatch.messages.count, 3)
            try expectEqual(firstBatch.messages[0].senderRole, .bot)
            try expectEqual(firstBatch.messages[1].senderRole, .user)
            try expectEqual(firstBatch.messages[1].kind, .text)
            try expectEqual(firstBatch.messages[1].text, "done 1")
            try expectEqual(firstBatch.messages[2].senderRole, .user)
            try expectEqual(firstBatch.messages[2].kind, .audio)
            try expectEqual(firstBatch.messages[2].text, "回程地铁上想到把周报发给总监")

            try expectEqual(transcriber.receivedClips.count, 1)
            try expectEqual(transcriber.receivedClips[0].0, expectedAudioBytes)

            let secondBatch = try await botClient.pullMessages(sinceCursor: firstBatch.nextCursor)
            try expectEqual(secondBatch.messages.map(\.messageId), ["om_user_text_2"])
            try expectEqual(secondBatch.messages[0].text, "到家记得给猫换水")
            try expectEqual(secondBatch.nextCursor, "1732540005950#om_user_text_2")
            try expectEqual(transcriber.receivedClips.count, 1, "Already-seen sub-second audio item must not be re-downloaded")
        }
    },
    TestCase(name: "end_to_end_24h_shift_journey_with_feishu_rest_bridge_and_sqlite") {
        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let voiceBytes = Data([0x4F, 0x67, 0x67, 0x53, 0x11, 0x22])
                let transcriber = FakeAudioTranscriber(stubbedTranscript: "明早给支付网关加上超时重试告警")
                let intelligence = StubPrepIntelligence(
                    prepBySubstring: ["鸡蛋": "土鸡蛋一盒"],
                    defaultPrep: "1. Check retry backoff\n2. Add alert threshold"
                )

                let session = StubURLProtocol.makeSession { req in
                    if req.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
                        let json = #"{"code":0,"msg":"ok","tenant_access_token":"t-e2e","expire":7200}"#
                        return (200, ["Content-Type": "application/json"], Data(json.utf8))
                    }
                    if req.url.path == "/open-apis/im/v1/messages" && req.method == "POST" {
                        let json = #"{"code":0,"msg":"success","data":{"message_id":"om_card_out_1"}}"#
                        return (200, ["Content-Type": "application/json"], Data(json.utf8))
                    }
                    if req.url.path == "/open-apis/im/v1/messages" && req.method == "GET" {
                        let json = """
                        {
                          "code": 0,
                          "msg": "success",
                          "data": {
                            "has_more": false,
                            "items": [
                              {
                                "message_id": "om_card_out_1",
                                "msg_type": "interactive",
                                "create_time": "1732550001000",
                                "sender": { "id": "cli_e2e", "sender_type": "app" },
                                "body": { "content": "{}" }
                              },
                              {
                                "message_id": "om_done_reply",
                                "msg_type": "text",
                                "create_time": "1732550002000",
                                "sender": { "id": "ou_1", "sender_type": "user" },
                                "body": { "content": "{\\"text\\":\\"完成 1\\"}" }
                              },
                              {
                                "message_id": "om_subway_voice",
                                "msg_type": "audio",
                                "create_time": "1732550003000",
                                "sender": { "id": "ou_1", "sender_type": "user" },
                                "body": { "content": "{\\"file_key\\":\\"file_e2e_voice\\"}" }
                              }
                            ]
                          }
                        }
                        """
                        return (200, ["Content-Type": "application/json"], Data(json.utf8))
                    }
                    if req.url.path == "/open-apis/im/v1/messages/om_subway_voice/resources/file_e2e_voice" {
                        return (200, ["Content-Type": "application/octet-stream"], voiceBytes)
                    }
                    return (404, [:], Data())
                }

                let feishu = FeishuMobileBridgeClient(
                    config: MobileBridgeConfig(appId: "cli_e2e", appSecret: "sec_e2e", chatId: "oc_e2e"),
                    session: session,
                    audioTranscriber: transcriber,
                    now: { Date(timeIntervalSince1970: 1_732_550_010) }
                )
                let engine = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: intelligence,
                    mobileBridge: feishu,
                    audioTranscriber: transcriber
                )

                let l1 = try engine.drop("下班去超市买鸡蛋")
                let l2 = try engine.drop("给猫买冻干", lane: .life)
                let l3 = try engine.drop("周末车险续保", lane: .life)
                let l4 = try engine.drop("下周约牙医洗牙", lane: .life)
                _ = try await engine.awaitPrep(id: l1.id)
                _ = try await engine.awaitPrep(id: l2.id)
                _ = try await engine.awaitPrep(id: l3.id)
                _ = try await engine.awaitPrep(id: l4.id)

                let lockResult = try await engine.shiftAndSync(to: .life)
                let sleepResult = try await engine.shiftAndSync(to: .life)
                try expectEqual(lockResult.pushedLifeDock, true)
                try expectEqual(sleepResult.pushedLifeDock, false)

                let postReqs = StubURLProtocol.requests().filter { $0.url.path == "/open-apis/im/v1/messages" && $0.method == "POST" }
                try expectEqual(postReqs.count, 1)

                let wakeResult = try await engine.shiftAndSync(to: .work)
                try expectEqual(wakeResult.snapshot.activeLane, .work)
                try expectEqual(wakeResult.snapshot.berths.map(\.raw), ["明早给支付网关加上超时重试告警"])
                try expectEqual(wakeResult.snapshot.berths[0].prepState, .ready)
                try expectEqual(wakeResult.snapshot.berths[0].prep, "1. Check retry backoff\n2. Add alert threshold")

                let updatedLife = try engine.getDock(lane: .life)
                try expectEqual(updatedLife.berths.map(\.id).contains(l4.id), true, "Queued l4 promoted after '完成 1'")
                try expectEqual(updatedLife.berths.map(\.id).contains(l1.id), false, "Resolved l1 sunk to Deep")
            }
        }
    },
    TestCase(name: "openai_compatible_client_parses_chat_prep_and_lane_for_text_only_provider") {
        try runAsyncTest {
            let session = StubURLProtocol.makeSession { request in
                guard request.url.absoluteString == "https://api.deepseek.com/v1/chat/completions" else {
                    throw TestFailure("Unexpected endpoint: \(request.url.absoluteString)")
                }
                guard request.method == "POST" else {
                    throw TestFailure("Expected POST, got \(request.method)")
                }
                guard request.header("Authorization") == "Bearer sk-deepseek-test" else {
                    throw TestFailure("Missing or wrong Authorization header")
                }
                let bodyText = String(data: request.body, encoding: .utf8) ?? ""
                guard bodyText.contains("deepseek-chat"), bodyText.contains("Order HEPA filter") else {
                    throw TestFailure("Request body missing model or raw Drop: \(bodyText)")
                }

                let completionJSON = """
                {
                  "choices": [
                    {
                      "message": {
                        "role": "assistant",
                        "content": "```json\\n{\\"lane\\": \\"life\\", \\"prep\\": \\"1. Check purifier model dimensions\\\\n2. Compare H13 HEPA two-pack\\\\n3. Order for Friday delivery\\\\n4. Extra line that must be trimmed\\"}\\n```"
                      }
                    }
                  ]
                }
                """
                return (200, ["Content-Type": "application/json"], Data(completionJSON.utf8))
            }

            let config = OpenAICompatibleConfiguration(
                baseURL: URL(string: "https://api.deepseek.com/v1")!,
                apiKey: "sk-deepseek-test",
                model: "deepseek-chat",
                asrEndpointURL: nil
            )
            let client = OpenAICompatibleIntelligenceClient(configuration: config, urlSession: session)
            try expectEqual(client.hasAudioTranscriptionEndpoint, false)

            let analysis = await client.prepareDrop(raw: "Order HEPA filter before weekend guests arrive", explicitLane: nil)
            try expectEqual(analysis.lane, .life)
            try expectEqual(analysis.prepState, .ready)
            let lines = (analysis.prep ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty }
            try expectEqual(lines.count, 3, "Prep must be clamped to at most 3 concise lines")
            try expectEqual(lines.first, "1. Check purifier model dimensions")

            let asrText = await client.transcribeAudio(data: Data([0x00, 0x01]), filename: "voice.wav", mimeType: "audio/wav")
            try expectEqual(asrText, nil)
        }
    },
    TestCase(name: "openai_compatible_client_falls_back_gracefully_offline_and_supports_optional_asr_endpoint") {
        try runAsyncTest {
            let offlineSession = StubURLProtocol.makeSession { _ in
                throw URLError(.notConnectedToInternet)
            }
            let offlineClient = OpenAICompatibleIntelligenceClient(
                configuration: OpenAICompatibleConfiguration(
                    baseURL: URL(string: "https://api.openai.com/v1")!,
                    apiKey: "sk-offline-test",
                    model: "gpt-4o-mini"
                ),
                urlSession: offlineSession
            )
            let offlineLife = await offlineClient.prepareDrop(raw: "下班去药店买退烧贴", explicitLane: nil)
            try expectEqual(offlineLife.lane, .life)
            try expectEqual(offlineLife.prep, nil)
            try expectEqual(offlineLife.prepState, .skipped)

            let unconfiguredClient = OpenAICompatibleIntelligenceClient(
                configuration: .unconfigured,
                urlSession: StubURLProtocol.makeSession { _ in
                    throw TestFailure("Unconfigured client must not issue network requests")
                }
            )
            let localWork = await unconfiguredClient.prepareDrop(raw: "Investigate SQLite WAL lock contention", explicitLane: nil)
            try expectEqual(localWork.lane, .work)
            try expectEqual(localWork.prepState, .skipped)

            let asrSession = StubURLProtocol.makeSession { request in
                guard request.url.absoluteString == "https://api.openai.com/v1/audio/transcriptions" else {
                    throw TestFailure("Unexpected ASR URL: \(request.url.absoluteString)")
                }
                guard request.header("Authorization") == "Bearer sk-asr-key" else {
                    throw TestFailure("Missing Authorization header on ASR request")
                }
                let contentType = request.header("Content-Type") ?? ""
                guard contentType.contains("multipart/form-data; boundary=") else {
                    throw TestFailure("Expected multipart/form-data Content-Type, got \(contentType)")
                }
                let bodyStr = String(decoding: request.body, as: UTF8.self)
                guard bodyStr.contains("whisper-1"), bodyStr.contains("filename=\"drop.wav\"") else {
                    throw TestFailure("Multipart body missing model or filename")
                }

                return (200, ["Content-Type": "application/json"], Data(#"{"text": "下班顺路去丰巢取生鲜快递"}"#.utf8))
            }

            let asrClient = OpenAICompatibleIntelligenceClient(
                configuration: OpenAICompatibleConfiguration(
                    baseURL: URL(string: "https://api.deepseek.com/v1")!,
                    apiKey: "sk-asr-key",
                    model: "deepseek-chat",
                    asrEndpointURL: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                    asrModel: "whisper-1"
                ),
                urlSession: asrSession
            )
            try expectEqual(asrClient.hasAudioTranscriptionEndpoint, true)
            let transcript = await asrClient.transcribeAudio(
                data: Data("fake-wav-bytes".utf8),
                filename: "drop.wav",
                mimeType: "audio/wav"
            )
            try expectEqual(transcript, "下班顺路去丰巢取生鲜快递")
        }
    },
    TestCase(name: "drop_asynchronously_attaches_concise_prep_and_smart_lane_triage_without_mutating_sacred_raw") {
        struct FakePrepIntelligence: IntelligenceClient {
            let simulatedOffline: Bool

            func prepareDrop(raw: String, explicitLane: Lane?) async -> DropPrepAnalysis {
                if simulatedOffline {
                    return DropPrepAnalysis(
                        lane: explicitLane ?? DockEngine.inferLaneLocally(for: raw),
                        prep: nil,
                        prepState: .skipped
                    )
                }
                let smartLane: Lane = raw.contains("HEPA") ? .life : .work
                let verbosePrep = """
                1. Check living-room purifier filter code
                2. Order two-pack before 6pm cutoff
                3. Swap filter before Sunday
                4. Fourth line should be clamped by DockEngine
                """
                return DropPrepAnalysis(lane: smartLane, prep: verbosePrep, prepState: .ready)
            }
        }

        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let engine = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: FakePrepIntelligence(simulatedOffline: false)
                )

                let w1 = try engine.drop("W1: Benchmark query planner", lane: .work)
                let w2 = try engine.drop("W2: Review API contract", lane: .work)
                let sacredAmbiguousRaw = "  Order HEPA filter before Sunday guests arrive! [verbatim]  "
                let autoDrop = try engine.drop(sacredAmbiguousRaw)
                let wQueued = try engine.drop("W4: Queued work waiting for vacated berth", lane: .work)
                let explicitOverride = try engine.drop("Audit HEPA cleanroom spec at office", lane: .work)

                let preparedAuto = try await engine.awaitPrep(id: autoDrop.id)
                try expectEqual(preparedAuto.raw, sacredAmbiguousRaw, "raw text must NEVER be mutated by Prep")
                try expectEqual(preparedAuto.lane, .life, "AI smart triage should move unpinned errand to Life")
                try expectEqual(preparedAuto.status, .docked)
                try expectEqual(preparedAuto.prepState, .ready)
                let prepLines = (preparedAuto.prep ?? "").components(separatedBy: .newlines)
                try expectEqual(prepLines.count, 3, "Prep attached to DockItem must have <= 3 lines")

                let preparedOverride = try await engine.awaitPrep(id: explicitOverride.id)
                try expectEqual(preparedOverride.lane, .work, "Explicit lane override must never be overridden by AI")

                _ = try await engine.awaitPrep(id: w1.id)
                _ = try await engine.awaitPrep(id: w2.id)
                _ = try await engine.awaitPrep(id: wQueued.id)

                let workDock = try engine.getDock(lane: .work)
                try expectEqual(workDock.berths.map(\.id), [w1.id, w2.id, wQueued.id])
                try expectEqual(workDock.queuedCount, 1)

                let lifeDock = try engine.getDock(lane: .life)
                try expectEqual(lifeDock.berths.map(\.id), [autoDrop.id])
                try expectEqual(lifeDock.berths[0].raw, sacredAmbiguousRaw)
                try expectEqual(lifeDock.berths[0].prepState, .ready)

                let reopened = try DockEngine(databasePath: dbPath)
                let persistedLife = try reopened.getDock(lane: .life)
                try expectEqual(persistedLife.berths.first?.prep, preparedAuto.prep)
                try expectEqual(persistedLife.berths.first?.prepState, .ready)
                try expectEqual(persistedLife.berths.first?.raw, sacredAmbiguousRaw)
            }

            try await withTempDatabasePathAsync { dbPath in
                let offlineEngine = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: FakePrepIntelligence(simulatedOffline: true)
                )
                let raw = "买退烧贴和体温计"
                let dropped = try offlineEngine.drop(raw)
                try expectEqual(dropped.lane, .life)
                let afterFallback = try await offlineEngine.awaitPrep(id: dropped.id)
                try expectEqual(afterFallback.prepState, .skipped)
                try expectEqual(afterFallback.prep, nil)
                try expectEqual(afterFallback.raw, raw)
            }
        }
    },
    TestCase(name: "openai_compatible_client_ranks_vague_recall_via_llm_and_offline_synonym_fallback") {
        try runAsyncTest {
            let candidates = [
                DockItem(
                    id: "d1",
                    raw: "排查支付回调偶发 504 网关报错",
                    lane: .work,
                    status: .deep,
                    prep: "Check upstream Nginx proxy_read_timeout",
                    prepState: .ready
                ),
                DockItem(
                    id: "d2",
                    raw: "调研 WebAuthn Passkey 免密方案",
                    lane: .work,
                    status: .deep,
                    prep: "Compare platform authenticator support on macOS/Android",
                    prepState: .ready
                ),
                DockItem(
                    id: "d3",
                    raw: "周末给老车办续保手续",
                    lane: .life,
                    status: .deep,
                    prep: nil,
                    prepState: .skipped
                )
            ]

            let onlineSession = StubURLProtocol.makeSession { request in
                let bodyText = String(decoding: request.body, as: UTF8.self)
                guard bodyText.contains("passwordless login idea"),
                      bodyText.contains("d1"),
                      bodyText.contains("d2"),
                      bodyText.contains("d3") else {
                    throw TestFailure("Recall prompt missing query or candidate IDs: \(bodyText)")
                }

                let llmPayload = """
                {
                  "choices": [
                    {
                      "message": {
                        "role": "assistant",
                        "content": "{\\"matched_ids\\": [\\"d2\\"]}"
                      }
                    }
                  ]
                }
                """
                return (200, ["Content-Type": "application/json"], Data(llmPayload.utf8))
            }

            let onlineClient = OpenAICompatibleIntelligenceClient(
                configuration: OpenAICompatibleConfiguration(
                    baseURL: URL(string: "https://api.deepseek.com/v1")!,
                    apiKey: "sk-recall-key",
                    model: "deepseek-chat"
                ),
                urlSession: onlineSession
            )
            let onlineMatches = await onlineClient.rankRecall(query: "passwordless login idea", candidates: candidates)
            try expectEqual(onlineMatches.map(\.id), ["d2"])
            try expectEqual(onlineMatches.first?.raw, "调研 WebAuthn Passkey 免密方案")

            let offlineSession = StubURLProtocol.makeSession { _ in
                throw URLError(.notConnectedToInternet)
            }
            let offlineClient = OpenAICompatibleIntelligenceClient(
                configuration: OpenAICompatibleConfiguration(
                    baseURL: URL(string: "https://api.deepseek.com/v1")!,
                    apiKey: "sk-recall-key",
                    model: "deepseek-chat"
                ),
                urlSession: offlineSession
            )

            let authFallback = await offlineClient.rankRecall(query: "authentication signin", candidates: candidates)
            try expectEqual(authFallback.first?.id, "d2")

            let carFallback = await offlineClient.rankRecall(query: "car policy renewal", candidates: candidates)
            try expectEqual(carFallback.first?.id, "d3")
        }
    },
    TestCase(name: "recall_retrieves_deep_items_by_vague_impression_and_resurface_respects_three_berth_cap") {
        struct ContextualRecallFake: IntelligenceClient {
            func prepareDrop(raw: String, explicitLane: Lane?) async -> DropPrepAnalysis {
                let lane = explicitLane ?? DockEngine.inferLaneLocally(for: raw)
                return DropPrepAnalysis(lane: lane, prep: "Prepared cue for: \(raw.prefix(18))", prepState: .ready)
            }

            func rankRecall(query: String, candidates: [DockItem]) async -> [DockItem] {
                if query.localizedCaseInsensitiveContains("stripe gateway") {
                    let first = candidates.filter { $0.raw.contains("504") }
                    let second = candidates.filter { $0.raw.contains("Webhook") }
                    return first + second
                }
                return LocalRecallRanker.rank(query: query, candidates: candidates)
            }
        }

        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let engine = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: ContextualRecallFake()
                )

                let active1 = try engine.drop("Active 1: Current 504 investigation on Dock", lane: .work)
                let active2 = try engine.drop("Active 2: Active sprint task", lane: .work)

                let sacredDeep1 = "  排查上个月支付回调偶发 504 超时根因  "
                let deep1 = try engine.drop(sacredDeep1, lane: .work)
                let deep2 = try engine.drop("Webhook 签名重试幂等笔记", lane: .work)
                let deep3 = try engine.drop("老家父母年度体检预约医院清单", lane: .life)

                _ = try await engine.awaitPrep(id: active1.id)
                _ = try await engine.awaitPrep(id: active2.id)
                _ = try await engine.awaitPrep(id: deep1.id)
                _ = try await engine.awaitPrep(id: deep2.id)
                _ = try await engine.awaitPrep(id: deep3.id)

                _ = try engine.reclassify(id: deep1.id, to: .deep)
                _ = try engine.reclassify(id: deep2.id, to: .deep)
                _ = try engine.reclassify(id: deep3.id, to: .deep)

                let emptyHits = try await engine.recall(query: "   ")
                try expectEqual(emptyHits, [])

                let ranked = try await engine.recall(query: "that stripe gateway issue from weeks ago")
                try expectEqual(ranked.map(\.id), [deep1.id, deep2.id], "Recall must rank matching Deep items and exclude active Dock items")
                try expectEqual(ranked[0].raw, sacredDeep1, "Sacred raw wording must be preserved in Recall")

                let medicalHits = try await engine.recall(query: "doctor clinic health check")
                try expectEqual(medicalHits.map(\.id), [deep3.id])

                let resurfacedOpen = try engine.resurface(id: deep3.id)
                try expectEqual(resurfacedOpen.status, .docked)
                try expectEqual(resurfacedOpen.lane, .work)
                try expectEqual(resurfacedOpen.raw, "老家父母年度体检预约医院清单")

                let dockAtCap = try engine.getDock(lane: .work)
                try expectEqual(dockAtCap.berths.map(\.id), [active1.id, active2.id, deep3.id])
                try expectEqual(dockAtCap.queuedCount, 0)
                try expectEqual(dockAtCap.deepCount, 2)

                let resurfacedQueued = try engine.resurface(id: deep1.id)
                try expectEqual(resurfacedQueued.status, .queued)
                try expectEqual(resurfacedQueued.raw, sacredDeep1)

                let dockWithQueue = try engine.getDock(lane: .work)
                try expectEqual(dockWithQueue.berths.count, 3)
                try expectEqual(dockWithQueue.queuedCount, 1)
                try expectEqual(dockWithQueue.deepCount, 1)

                let resolved = try engine.resolveBerth(id: active2.id)
                try expectEqual(resolved.promotedItem?.id, deep1.id)
            }
        }
    },
    TestCase(name: "settings_store_persists_0600_config_syncs_wizard_dotenv_and_redacts_secrets") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindDockSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configDir = tempRoot.appendingPathComponent("minddock-config", isDirectory: true)
        let configJSONURL = configDir.appendingPathComponent("config.json")
        let dotEnvURL = configDir.appendingPathComponent(".env")

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let wizardDotEnv = """
        MINDDOCK_LLM_BASE_URL='https://api.openai.com/v1'
        MINDDOCK_LLM_API_KEY='sk-wizard-initial-secret'
        MINDDOCK_LLM_MODEL='gpt-4o-mini'
        MINDDOCK_ASR_URL='https://api.openai.com/v1/audio/transcriptions'
        MINDDOCK_FEISHU_APP_ID='cli_wiz_app_01'
        MINDDOCK_FEISHU_APP_SECRET='sec_wiz_secret_01'
        MINDDOCK_FEISHU_CHAT_ID='oc_wiz_chat_01'
        """
        try Data(wizardDotEnv.utf8).write(to: dotEnvURL)

        let storeFromWizard = MindDockSettingsStore(
            configJSONURL: configJSONURL,
            primaryDotEnvURL: dotEnvURL,
            additionalDotEnvURLs: [],
            environment: [:],
            defaults: nil
        )
        let loadedFromWizard = storeFromWizard.load()
        try expectEqual(loadedFromWizard.llmBaseURL, "https://api.openai.com/v1")
        try expectEqual(loadedFromWizard.llmAPIKey, "sk-wizard-initial-secret")
        try expectEqual(loadedFromWizard.llmModel, "gpt-4o-mini")
        try expectEqual(loadedFromWizard.asrEndpointURL, "https://api.openai.com/v1/audio/transcriptions")
        try expectEqual(loadedFromWizard.feishuAppId, "cli_wiz_app_01")
        try expectEqual(loadedFromWizard.feishuAppSecret, "sec_wiz_secret_01")
        try expectEqual(loadedFromWizard.feishuChatId, "oc_wiz_chat_01")
        try expectEqual(loadedFromWizard.openAIConfiguration.isConfigured, true)
        try expectEqual(loadedFromWizard.mobileBridgeConfig?.hasAppBotCredentials, true)

        var updated = loadedFromWizard
        updated.llmBaseURL = "https://api.deepseek.com/v1"
        updated.llmAPIKey = "sk-live-it's-super-secret-999"
        updated.llmModel = "deepseek-chat"
        updated.speechLocale = .enUS
        updated.feishuAppSecret = "sec-app-secret-888"
        updated.feishuWebhookURL = "https://open.feishu.cn/open-apis/bot/v2/hook/secret-hook-token-777"
        try storeFromWizard.save(updated)

        let jsonAttrs = try FileManager.default.attributesOfItem(atPath: configJSONURL.path)
        let envAttrs = try FileManager.default.attributesOfItem(atPath: dotEnvURL.path)
        let jsonMode = (jsonAttrs[.posixPermissions] as? Int ?? 0) & 0o777
        let envMode = (envAttrs[.posixPermissions] as? Int ?? 0) & 0o777
        try expectEqual(jsonMode, 0o600, "config.json must have 0600 permissions")
        try expectEqual(envMode, 0o600, ".env must have 0600 permissions")

        let reloaded = storeFromWizard.load()
        try expectEqual(reloaded, updated)
        let dotEnvContent = try String(contentsOf: dotEnvURL, encoding: .utf8)
        try expectTrue(
            dotEnvContent.contains("MINDDOCK_LLM_API_KEY='sk-live-it'\\''s-super-secret-999'"),
            ".env must escape single quotes compatibly with setup-wizard.sh _existing()"
        )
        try expectTrue(
            !dotEnvContent.contains("PUSHPLUS"),
            "Removed PushPlus scope creep must never appear in .env"
        )

        let envOverrideStore = MindDockSettingsStore(
            configJSONURL: configJSONURL,
            primaryDotEnvURL: dotEnvURL,
            additionalDotEnvURLs: [],
            environment: ["MINDDOCK_LLM_MODEL": "deepseek-reasoner"],
            defaults: nil
        )
        try expectEqual(envOverrideStore.load().llmModel, "deepseek-reasoner")
        try expectEqual(envOverrideStore.load().llmAPIKey, "sk-live-it's-super-secret-999")

        let desc = String(describing: reloaded)
        let debugDesc = String(reflecting: reloaded)
        let summary = reloaded.redactedSummary
        for text in [desc, debugDesc, summary] {
            try expectTrue(!text.contains("sk-live-it's-super-secret-999"), "API key must never appear in description/logs")
            try expectTrue(!text.contains("sec-app-secret-888"), "Feishu App Secret must never appear in description/logs")
            try expectTrue(!text.contains("secret-hook-token-777"), "Webhook token must never appear in description/logs")
        }
    },
    TestCase(name: "dock_engine_hot_reloads_intelligence_client_and_verifies_llm_connection") {
        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let unconfigured = OpenAICompatibleIntelligenceClient(configuration: .unconfigured)
                let engine = try DockEngine(databasePath: dbPath, intelligenceClient: unconfigured)

                var caughtMissingKey = false
                do {
                    _ = try await engine.testIntelligenceConnection()
                } catch IntelligenceConnectionError.missingAPIKey {
                    caughtMissingKey = true
                }
                try expectTrue(caughtMissingKey, "Unconfigured LLM client must throw IntelligenceConnectionError.missingAPIKey via DockEngine")

                let firstDrop = try engine.drop("Order H13 HEPA filter before guests arrive")
                let firstPrepared = try await engine.awaitPrep(id: firstDrop.id)
                try expectEqual(firstPrepared.prepState, .skipped)
                try expectEqual(firstPrepared.prep, nil)

                let unauthorizedSession = StubURLProtocol.makeSession { _ in
                    (401, ["Content-Type": "application/json"], Data(#"{"error":{"message":"Invalid authentication token"}}"#.utf8))
                }
                let badKeyClient = OpenAICompatibleIntelligenceClient(
                    configuration: OpenAICompatibleConfiguration(
                        baseURL: URL(string: "https://api.deepseek.com/v1")!,
                        apiKey: "sk-bad-key",
                        model: "deepseek-chat"
                    ),
                    urlSession: unauthorizedSession
                )
                engine.setIntelligenceClient(badKeyClient)
                var caught401 = false
                do {
                    _ = try await engine.testIntelligenceConnection()
                } catch let IntelligenceConnectionError.httpStatus(code, detail) {
                    caught401 = (code == 401 && detail.contains("Invalid authentication token"))
                }
                try expectTrue(caught401, "HTTP 401 must surface status code and error message")

                let liveSession = StubURLProtocol.makeSession { req in
                    let bodyText = String(decoding: req.body, as: UTF8.self)
                    let content: String
                    if bodyText.contains("ping") {
                        content = "OK"
                    } else {
                        content = #"{"lane":"life","prep":"1. Check filter dimensions\n2. Order H13 two-pack"}"#
                    }
                    let json = """
                    {"choices":[{"message":{"role":"assistant","content":\(String(decoding: try JSONEncoder().encode(content), as: UTF8.self))}}]}
                    """
                    return (200, ["Content-Type": "application/json"], Data(json.utf8))
                }
                let liveSettings = MindDockSettings(
                    llmBaseURL: "https://api.deepseek.com/v1",
                    llmAPIKey: "sk-valid-hot-reload",
                    llmModel: "deepseek-chat"
                )
                let adapters = MindDockRuntimeAdapters.make(from: liveSettings, urlSession: liveSession)
                engine.applyAdapters(adapters)

                let probeSummary = try await engine.testIntelligenceConnection()
                try expectTrue(probeSummary.contains("deepseek-chat"), "Connection summary should confirm active model")

                let secondDrop = try engine.drop("Replace purifier filter before Sunday")
                let secondPrepared = try await engine.awaitPrep(id: secondDrop.id)
                try expectEqual(secondPrepared.lane, .life, "Hot-reloaded LLM client must classify new Drops immediately")
                try expectEqual(secondPrepared.prepState, .ready)
                try expectTrue((secondPrepared.prep ?? "").contains("Order H13 two-pack"), "Hot-reloaded LLM client must attach Prep")
            }
        }
    },
    TestCase(name: "test_mobile_push_sends_preview_when_empty_and_forces_live_push_when_deduplicated") {
        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let engine = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: StubPrepIntelligence(prepBySubstring: ["丰巢": "取件码 9012"])
                )

                var caughtUnconfigured = false
                do {
                    _ = try await engine.testMobilePush()
                } catch MobileBridgeError.unconfigured {
                    caughtUnconfigured = true
                }
                try expectTrue(caughtUnconfigured, "testMobilePush must throw MobileBridgeError.unconfigured when nil")

                let bridge = FakeMobileBridgeClient()
                engine.setMobileBridge(bridge)

                let previewResult = try await engine.testMobilePush()
                try expectEqual(previewResult.usedSamplePreview, true)
                try expectEqual(previewResult.pushedBerthCount, 1)
                try expectEqual(bridge.pushedPayloads.count, 1)
                try expectEqual(try engine.getDock(lane: .life).berths.count, 0, "Preview push must not insert fake items into SQLite")

                let realLife = try engine.drop("下班去丰巢取冷链快递", lane: .life)
                _ = try await engine.awaitPrep(id: realLife.id)
                let firstShift = try await engine.shiftAndSync(to: .life)
                let duplicateShift = try await engine.shiftAndSync(to: .life)
                try expectEqual(firstShift.pushedLifeDock, true)
                try expectEqual(duplicateShift.pushedLifeDock, false)
                try expectEqual(bridge.pushedPayloads.count, 2)

                let forcedResult = try await engine.testMobilePush()
                try expectEqual(forcedResult.usedSamplePreview, false)
                try expectEqual(forcedResult.pushedBerthCount, 1)
                try expectEqual(bridge.pushedPayloads.count, 3, "testMobilePush must force push even when Life Dock was already deduplicated")
                try expectEqual(bridge.pushedPayloads[2].berths.first?.raw, "下班去丰巢取冷链快递")
                try expectEqual(bridge.pushedPayloads[2].berths.first?.prep, "取件码 9012")
            }
        }
    },
    TestCase(name: "regression_mobile_drop_runs_real_llm_prep_and_smart_lane_triage_and_falls_back_cleanly_when_skipped") {
        struct SmartMobileIntelligence: IntelligenceClient {
            let isOnline: Bool
            func prepareDrop(raw: String, explicitLane: Lane?) async -> DropPrepAnalysis {
                guard isOnline else {
                    return DropPrepAnalysis(
                        lane: explicitLane ?? DockEngine.inferLaneLocally(for: raw),
                        prep: nil,
                        prepState: .skipped
                    )
                }
                if raw.contains("HEPA") {
                    return DropPrepAnalysis(
                        lane: .life,
                        prep: "1. Measure purifier slot\n2. Order H13 twin-pack",
                        prepState: .ready
                    )
                }
                return DropPrepAnalysis(
                    lane: .work,
                    prep: "1. Check webhook lock ordering\n2. Add SQLite busy_timeout test",
                    prepState: .ready
                )
            }
        }

        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let bridge = FakeMobileBridgeClient()
                bridge.queuedBatches = [
                    InboundMessageBatch(
                        messages: [
                            InboundMobileMessage(
                                messageId: "om_mobile_hepa",
                                senderRole: .user,
                                kind: .text,
                                text: "Order H13 HEPA replacement before Sunday",
                                createdAtTimestamp: "1732560001000"
                            )
                        ],
                        nextCursor: "1732560001000#om_mobile_hepa"
                    )
                ]

                let engine = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: SmartMobileIntelligence(isOnline: true),
                    mobileBridge: bridge
                )

                let report = try await engine.syncMobileBridge()
                try expectEqual(report.droppedItems.count, 1)
                try expectEqual(report.droppedItems[0].lane, .life, "Mobile Drop should receive LLM smart lane triage to Life")
                try expectEqual(report.droppedItems[0].prepState, .ready)
                try expectEqual(
                    report.droppedItems[0].prep,
                    "1. Measure purifier slot\n2. Order H13 twin-pack",
                    "Mobile Drop must receive real LLM Prep rather than static boilerplate"
                )

                let lifeDock = try engine.getDock(lane: .life)
                try expectEqual(lifeDock.berths.count, 1)
                try expectEqual(lifeDock.berths[0].prep, "1. Measure purifier slot\n2. Order H13 twin-pack")
            }

            try await withTempDatabasePathAsync { dbPath in
                let bridge = FakeMobileBridgeClient()
                bridge.queuedBatches = [
                    InboundMessageBatch(
                        messages: [
                            InboundMobileMessage(
                                messageId: "om_mobile_offline",
                                senderRole: .user,
                                kind: .text,
                                text: "排查线上 Redis 连接池偶发抖动",
                                createdAtTimestamp: "1732560002000"
                            )
                        ],
                        nextCursor: "1732560002000#om_mobile_offline"
                    )
                ]
                let offlineEngine = try DockEngine(
                    databasePath: dbPath,
                    intelligenceClient: SmartMobileIntelligence(isOnline: false),
                    mobileBridge: bridge
                )
                let offlineReport = try await offlineEngine.syncMobileBridge()
                try expectEqual(offlineReport.droppedItems.count, 1)
                try expectEqual(offlineReport.droppedItems[0].lane, .work)
                try expectEqual(offlineReport.droppedItems[0].prepState, .skipped)
                try expectEqual(offlineReport.droppedItems[0].prep, nil)
            }
        }
    },
    TestCase(name: "regression_failing_audio_attachment_does_not_wedge_feishu_sync_or_cursor") {
        struct ThrowingTranscriber: AudioTranscriber {
            func transcribe(audioData: Data, fileExtension: String) async throws -> String {
                throw MobileBridgeError.transcriptionFailed("Simulated corrupt opus stream")
            }
        }

        try runAsyncTest {
            try await withTempDatabasePathAsync { dbPath in
                let session = StubURLProtocol.makeSession { req in
                    if req.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
                        return (200, ["Content-Type": "application/json"], Data(#"{"code":0,"tenant_access_token":"t-audio-resilience","expire":7200}"#.utf8))
                    }
                    if req.url.path == "/open-apis/im/v1/messages" && req.method == "GET" {
                        let json = """
                        {
                          "code": 0,
                          "data": {
                            "has_more": false,
                            "items": [
                              {
                                "message_id": "om_bad_403_audio",
                                "msg_type": "audio",
                                "create_time": "1732570001000",
                                "sender": { "id": "ou_u1", "sender_type": "user" },
                                "body": { "content": "{\\"file_key\\":\\"file_403\\"}" }
                              },
                              {
                                "message_id": "om_corrupt_audio",
                                "msg_type": "audio",
                                "create_time": "1732570002000",
                                "sender": { "id": "ou_u1", "sender_type": "user" },
                                "body": { "content": "{\\"file_key\\":\\"file_corrupt\\"}" }
                              },
                              {
                                "message_id": "om_good_followup",
                                "msg_type": "text",
                                "create_time": "1732570003000",
                                "sender": { "id": "ou_u1", "sender_type": "user" },
                                "body": { "content": "{\\"text\\":\\"明早合并修复分支并发布\\"}" }
                              }
                            ]
                          }
                        }
                        """
                        return (200, ["Content-Type": "application/json"], Data(json.utf8))
                    }
                    if req.url.path == "/open-apis/im/v1/messages/om_bad_403_audio/resources/file_403" {
                        return (403, ["Content-Type": "application/json"], Data(#"{"code":99991672,"msg":"no permission"}"#.utf8))
                    }
                    if req.url.path == "/open-apis/im/v1/messages/om_corrupt_audio/resources/file_corrupt" {
                        return (200, ["Content-Type": "application/octet-stream"], Data([0xFF, 0x00, 0x11]))
                    }
                    return (404, [:], Data())
                }

                let feishu = FeishuMobileBridgeClient(
                    config: MobileBridgeConfig(appId: "cli_res", appSecret: "sec_res", chatId: "oc_res"),
                    session: session,
                    audioTranscriber: ThrowingTranscriber(),
                    now: { Date(timeIntervalSince1970: 1_732_570_010) }
                )
                let engine = try DockEngine(
                    databasePath: dbPath,
                    mobileBridge: feishu,
                    audioTranscriber: ThrowingTranscriber()
                )

                let report = try await engine.syncMobileBridge()
                try expectEqual(report.advancedCursor, "1732570003000#om_good_followup", "Cursor must advance past failing audio messages")
                try expectEqual(report.droppedItems.count, 3)
                try expectEqual(report.droppedItems[0].raw, InboundMobileMessage.audioTranscriptionFallbackText)
                try expectEqual(report.droppedItems[1].raw, InboundMobileMessage.audioTranscriptionFallbackText)
                try expectEqual(report.droppedItems[2].raw, "明早合并修复分支并发布")
            }
        }
    },
    TestCase(name: "regression_macos_audio_transcriber_converts_opus_to_16khz_wav_for_cloud_asr_guards_auth_and_supports_bilingual_locales") {
        try runAsyncTest {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MindDockAudioASRTest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cafURL = tempDir.appendingPathComponent("source.caf")
            let opusURL = tempDir.appendingPathComponent("source.opus")
            try writeSampleSineCAF(to: cafURL)

            // Encode real Opus audio container via /usr/bin/afconvert
            let encodeProc = Process()
            encodeProc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            encodeProc.arguments = ["-f", "caff", "-d", "opus", cafURL.path, opusURL.path]
            encodeProc.standardInput = FileHandle.nullDevice
            encodeProc.standardOutput = FileHandle.nullDevice
            encodeProc.standardError = FileHandle.nullDevice
            try encodeProc.run()
            encodeProc.waitUntilExit()
            try expectEqual(encodeProc.terminationStatus, 0, "afconvert must encode sample Opus audio")
            let opusBytes = try Data(contentsOf: opusURL)
            try expectTrue(!opusBytes.isEmpty, "Sample opus bytes must be non-empty")

            let asrSession = StubURLProtocol.makeSession { req in
                guard req.url.absoluteString == "https://api.openai.com/v1/audio/transcriptions" else {
                    throw TestFailure("Unexpected URL: \(req.url.absoluteString)")
                }
                let bodyText = String(decoding: req.body, as: UTF8.self)
                guard bodyText.contains("filename=\"clip.wav\""),
                      bodyText.contains("Content-Type: audio/wav"),
                      req.body.range(of: Data("RIFF".utf8)) != nil,
                      req.body.range(of: Data("WAVE".utf8)) != nil else {
                    throw TestFailure("Expected converted 16kHz RIFF WAVE upload, got: \(bodyText.prefix(200))")
                }
                return (200, ["Content-Type": "application/json"], Data(#"{"text":"Ship MindDock release bundle"}"#.utf8))
            }

            let cloudASRClient = OpenAICompatibleIntelligenceClient(
                configuration: OpenAICompatibleConfiguration(
                    baseURL: URL(string: "https://api.deepseek.com/v1")!,
                    apiKey: "sk-whisper-test",
                    model: "deepseek-chat",
                    asrEndpointURL: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                    asrModel: "whisper-1"
                ),
                urlSession: asrSession
            )

            // 1. Bilingual locale ordering check
            let zhTranscriber = MacOSAudioTranscriber(
                preferredLocale: .zhCN,
                intelligenceClient: cloudASRClient,
                speechAuthorizationStatusProvider: { .denied }
            )
            let enTranscriber = MacOSAudioTranscriber(
                preferredLocale: .enUS,
                intelligenceClient: nil,
                speechAuthorizationStatusProvider: { .denied }
            )
            try expectEqual(zhTranscriber.candidateLocaleIdentifiers, ["zh-CN", "en-US"])
            try expectEqual(enTranscriber.candidateLocaleIdentifiers, ["en-US", "zh-CN"])

            // 2. Cloud ASR route converts .opus -> 16kHz .wav and succeeds even when SFSpeechRecognizer auth is denied
            let cloudResult = try await zhTranscriber.transcribe(audioData: opusBytes, fileExtension: "opus")
            try expectEqual(cloudResult, "Ship MindDock release bundle")

            // 3. Without cloud ASR, denied SFSpeechRecognizer authorization fails cleanly before touching SFSpeechRecognizer
            var caughtDenied = false
            do {
                _ = try await enTranscriber.transcribe(audioData: opusBytes, fileExtension: "opus")
            } catch MobileBridgeError.transcriptionFailed {
                caughtDenied = true
            }
            try expectTrue(caughtDenied, "Denied speech authorization must throw MobileBridgeError.transcriptionFailed safely")
        }
    },
    TestCase(name: "regression_voice_capture_controller_uploads_wav_instead_of_caf_and_supports_hold_and_toggle_with_bilingual_locale") {
        final class FakeVoiceDriver: VoiceCaptureSessionDriver, @unchecked Sendable {
            private let lock = NSLock()
            private var active = false
            private var currentURL: URL?
            private(set) var startedLocales: [SpeechLocale] = []
            var emitLiveSpeech: String?

            var isHardwareActive: Bool {
                lock.withLock { active }
            }

            func start(
                locale: SpeechLocale,
                recordFallbackFile: Bool,
                onTranscript: @escaping @Sendable (String, Bool) -> Void,
                onError: @escaping @Sendable (String) -> Void
            ) async throws {
                var recorded: URL? = nil
                if recordFallbackFile {
                    let cafURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("fake-driver-\(UUID().uuidString).caf")
                    try writeSampleSineCAF(to: cafURL)
                    recorded = cafURL
                }
                lock.withLock {
                    active = true
                    startedLocales.append(locale)
                    currentURL = recorded
                }
                if let speech = emitLiveSpeech {
                    onTranscript(speech, false)
                }
            }

            func stop() -> URL? {
                lock.withLock {
                    active = false
                    let url = currentURL
                    currentURL = nil
                    return url
                }
            }
        }

        try runAsyncTest {
            try await Task { @MainActor in
                let tempCheck = VoiceCaptureController()
                try expectTrue(tempCheck.isHardwareReleased, "Voice hardware must start idle")

                // 1. Click-to-toggle (< 0.35s press) + bilingual locale switching
                let toggleDriver = FakeVoiceDriver()
                toggleDriver.emitLiveSpeech = "Review bilingual voice capture"

                let controller = VoiceCaptureController(driver: toggleDriver, speechLocale: .zhCN)
                controller.speechLocale = .enUS

                let t0 = Date(timeIntervalSince1970: 1_700_000_000)
                var capturedDraft = ""
                controller.beginMicPress(at: t0, currentDraft: "") { updated in
                    capturedDraft = updated
                }
                await controller.awaitCaptureStarted()
                try await Task.sleep(nanoseconds: 10_000_000)
                // Quick click release after 120ms (< 350ms threshold) keeps toggle recording active!
                controller.endMicPress(at: t0.addingTimeInterval(0.12))
                try expectEqual(controller.isRecording, true, "Quick click (<350ms) must stay recording in toggle mode")
                try expectEqual(toggleDriver.startedLocales, [.enUS], "Selected en-US locale must be passed to driver")
                try expectEqual(capturedDraft, "Review bilingual voice capture")

                // Second click stops recording and releases hardware immediately
                controller.beginMicPress(at: t0.addingTimeInterval(1.5), currentDraft: capturedDraft) { updated in
                    capturedDraft = updated
                }
                controller.endMicPress(at: t0.addingTimeInterval(1.6))
                try expectEqual(controller.isHardwareReleased, true, "Second click must stop capture and release audio hardware")

                // 2. Hold-to-speak (>= 0.35s press) + Cloud Whisper .caf -> .wav conversion
                let holdDriver = FakeVoiceDriver()
                holdDriver.emitLiveSpeech = nil // Force cloud ASR fallback from recorded .caf!

                let whisperSession = StubURLProtocol.makeSession { req in
                    let bodyStr = String(decoding: req.body, as: UTF8.self)
                    guard bodyStr.contains("filename=\"drop.wav\""),
                          bodyStr.contains("Content-Type: audio/wav"),
                          !bodyStr.contains("audio/x-caf"),
                          req.body.range(of: Data("RIFF".utf8)) != nil,
                          req.body.range(of: Data("WAVE".utf8)) != nil else {
                        throw TestFailure("VoiceCaptureController must convert .caf to RIFF WAVE drop.wav (audio/wav), got: \(bodyStr.prefix(200))")
                    }
                    return (200, ["Content-Type": "application/json"], Data(#"{"text":"按住说话自动转写为WAV上传"}"#.utf8))
                }
                let whisperClient = OpenAICompatibleIntelligenceClient(
                    configuration: OpenAICompatibleConfiguration(
                        baseURL: URL(string: "https://api.deepseek.com/v1")!,
                        apiKey: "sk-whisper",
                        model: "deepseek-chat",
                        asrEndpointURL: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                        asrModel: "whisper-1"
                    ),
                    urlSession: whisperSession
                )

                let holdController = VoiceCaptureController(
                    driver: holdDriver,
                    intelligenceClient: whisperClient,
                    hasASRFallbackEndpoint: true,
                    speechLocale: .zhCN
                )

                var holdDraft = ""
                holdController.beginMicPress(at: t0, currentDraft: "") { updated in
                    holdDraft = updated
                }
                await holdController.awaitCaptureStarted()
                // Release after 1.1s (>= 0.35s hold threshold) stops immediately on release and uploads WAV!
                holdController.endMicPress(at: t0.addingTimeInterval(1.1))
                await holdController.awaitPendingTranscription()

                try expectEqual(holdController.isHardwareReleased, true, "Releasing hold-to-speak must immediately release mic hardware")
                try expectEqual(holdDraft, "按住说话自动转写为WAV上传")
            }.value
        }
    },
    TestCase(name: "regression_settings_store_ignores_unrelated_cwd_dotenv_and_feishu_bounds_initial_history_and_filters_activation_pings") {
        let originalCwd = FileManager.default.currentDirectoryPath
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindDockCwdHijack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(originalCwd)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let unrelatedRepoDir = tempRoot.appendingPathComponent("unrelated-project", isDirectory: true)
        let isolatedConfigDir = tempRoot.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedRepoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: isolatedConfigDir, withIntermediateDirectories: true)

        try Data("OPENAI_API_KEY='sk-hijacked-from-unrelated-cwd'\nMINDDOCK_LLM_MODEL='hijacked-model'\n".utf8)
            .write(to: unrelatedRepoDir.appendingPathComponent(".env"))

        _ = FileManager.default.changeCurrentDirectoryPath(unrelatedRepoDir.path)

        let store = MindDockSettingsStore(
            configJSONURL: isolatedConfigDir.appendingPathComponent("config.json"),
            primaryDotEnvURL: isolatedConfigDir.appendingPathComponent(".env"),
            environment: [:],
            defaults: nil
        )
        let loaded = store.load()
        try expectEqual(loaded.llmAPIKey, "", "cwd/.env must never hijack MindDockSettingsStore")
        try expectEqual(loaded.llmModel, "deepseek-chat")

        try runAsyncTest {
            // Verify Feishu initial nil-cursor bounds ancient pre-pairing history, filters activation pings, and cursor "0" replays deterministically
            let simulatedNowSeconds: TimeInterval = 1_760_000_000 // recent epoch
            let ancientMs = "1700000000000" // months earlier -> must be skipped on nil cursor
            let recentPingMs = "1759999950000" // 50s ago -> bare "hi" activation ping
            let recentDropMs = "1759999980000" // 20s ago -> real mobile Drop

            let feishuSession = StubURLProtocol.makeSession { req in
                if req.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
                    return (200, ["Content-Type": "application/json"], Data(#"{"code":0,"tenant_access_token":"t-init-bound","expire":7200}"#.utf8))
                }
                if req.url.path == "/open-apis/im/v1/messages" && req.method == "GET" {
                    let json = """
                    {
                      "code": 0,
                      "data": {
                        "has_more": true,
                        "page_token": "ancient_page_2",
                        "items": [
                          {
                            "message_id": "om_ancient_pre_pair",
                            "msg_type": "text",
                            "create_time": "\(ancientMs)",
                            "sender": { "id": "ou_u1", "sender_type": "user" },
                            "body": { "content": "{\\"text\\":\\"半年前的群聊历史消息\\"}" }
                          },
                          {
                            "message_id": "om_activation_hi",
                            "msg_type": "text",
                            "create_time": "\(recentPingMs)",
                            "sender": { "id": "ou_u1", "sender_type": "user" },
                            "body": { "content": "{\\"text\\":\\"你好！\\"}" }
                          },
                          {
                            "message_id": "om_recent_drop",
                            "msg_type": "text",
                            "create_time": "\(recentDropMs)",
                            "sender": { "id": "ou_u1", "sender_type": "user" },
                            "body": { "content": "{\\"text\\":\\"hi team 评审一下新架构提案\\"}" }
                          }
                        ]
                      }
                    }
                    """
                    return (200, ["Content-Type": "application/json"], Data(json.utf8))
                }
                return (404, [:], Data())
            }

            let feishu = FeishuMobileBridgeClient(
                config: MobileBridgeConfig(appId: "cli_init", appSecret: "sec_init", chatId: "oc_init"),
                session: feishuSession,
                initialLookbackSeconds: 3600,
                now: { Date(timeIntervalSince1970: simulatedNowSeconds) }
            )

            try await withTempDatabasePathAsync { dbPath in
                let engine = try DockEngine(databasePath: dbPath, mobileBridge: feishu)
                let report = try await engine.syncMobileBridge()
                try expectEqual(
                    report.droppedItems.map(\.raw),
                    ["hi team 评审一下新架构提案"],
                    "Initial sync must skip ancient pre-pairing messages and bare activation pings"
                )
                try expectEqual(report.advancedCursor, "\(recentDropMs)#om_recent_drop")
            }

            // Explicit cursor "0" must still return messages from epoch 0 deterministically
            let replaySession = StubURLProtocol.makeSession { req in
                if req.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
                    return (200, ["Content-Type": "application/json"], Data(#"{"code":0,"tenant_access_token":"t-zero","expire":7200}"#.utf8))
                }
                if req.url.path == "/open-apis/im/v1/messages" && req.method == "GET" {
                    let json = """
                    {
                      "code": 0,
                      "data": {
                        "has_more": false,
                        "items": [
                          {
                            "message_id": "om_from_zero",
                            "msg_type": "text",
                            "create_time": "\(ancientMs)",
                            "sender": { "id": "ou_u1", "sender_type": "user" },
                            "body": { "content": "{\\"text\\":\\"从游标 0 确定性拉取的消息\\"}" }
                          }
                        ]
                      }
                    }
                    """
                    return (200, ["Content-Type": "application/json"], Data(json.utf8))
                }
                return (404, [:], Data())
            }
            let replayFeishu = FeishuMobileBridgeClient(
                config: MobileBridgeConfig(appId: "cli_zero", appSecret: "sec_zero", chatId: "oc_zero"),
                session: replaySession,
                now: { Date(timeIntervalSince1970: simulatedNowSeconds) }
            )
            let zeroBatch = try await replayFeishu.pullMessages(sinceCursor: "0")
            try expectEqual(zeroBatch.messages.map(\.text), ["从游标 0 确定性拉取的消息"])
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
        fflush(stdout)
        passed += 1
    } catch {
        fputs("FAIL \(test.name): \(error)\n", stderr)
        fflush(stderr)
        failed += 1
    }
}

print("\nSummary: \(passed) passed, \(failed) failed")
Foundation.exit(failed == 0 ? 0 : 1)
