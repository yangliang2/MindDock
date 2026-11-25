import AppKit
import Foundation
import MindDockCore

private final class SmokeVoiceDriver: VoiceCaptureSessionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    var isHardwareActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func start(
        recordFallbackFile: Bool,
        onTranscript: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        lock.withLock {
            active = true
        }
        onTranscript("调研 WebAuthn Passkey 免密方案", false)
    }

    func stop() -> URL? {
        lock.lock()
        active = false
        lock.unlock()
        return nil
    }
}

private struct SmokeIntelligence: IntelligenceClient {
    func prepareDrop(raw: String, explicitLane: Lane?) async -> DropPrepAnalysis {
        let lane = explicitLane ?? DockEngine.inferLaneLocally(for: raw)
        return DropPrepAnalysis(
            lane: lane,
            prep: "1. Verify platform authenticator\n2. Prototype credential registration",
            prepState: .ready
        )
    }
}

@MainActor
private func runSmokeCheck() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindDockSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let smokeConfigDir = tempDir.appendingPathComponent("config", isDirectory: true)
    let smokeStore = MindDockSettingsStore(
        configJSONURL: smokeConfigDir.appendingPathComponent("config.json"),
        primaryDotEnvURL: smokeConfigDir.appendingPathComponent(".env"),
        additionalDotEnvURLs: [],
        environment: [:],
        defaults: nil
    )

    let engine = try DockEngine(
        databasePath: tempDir.appendingPathComponent("smoke.sqlite3").path,
        intelligenceClient: SmokeIntelligence()
    )
    let smokeDriver = SmokeVoiceDriver()
    let voice = VoiceCaptureController(driver: smokeDriver)
    guard voice.isHardwareReleased else {
        throw DockError.storageFailure("Voice hardware should be idle on launch")
    }

    let vm = try DockViewModel(engine: engine, voiceController: voice, settingsStore: smokeStore)

    // 1. Toggle on-demand voice capture -> streams speech -> submit releases mic immediately
    vm.toggleVoiceCapture()
    try await Task.sleep(nanoseconds: 25_000_000)
    guard voice.isRecording, vm.draftText == "调研 WebAuthn Passkey 免密方案" else {
        throw DockError.storageFailure("Voice capture did not stream transcript into draftText")
    }

    guard vm.submitDraftDrop(), voice.isHardwareReleased, vm.snapshot.berths.count == 1 else {
        throw DockError.storageFailure("Submitting voice Drop failed or left audio hardware open")
    }

    let droppedID = vm.snapshot.berths[0].id
    let prepared = try await engine.awaitPrep(id: droppedID)
    vm.refresh()
    guard prepared.prepState == .ready, vm.snapshot.berths[0].prep != nil else {
        throw DockError.storageFailure("Background Prep did not attach ready note")
    }

    // 2. Sink to Deep, Recall by vague synonym impression, and Resurface to active Dock
    vm.sinkToDeep(id: droppedID)
    vm.setQuickBarMode(.recall)
    vm.recallQuery = "authentication signin"
    await vm.performRecall()
    guard vm.recallResults.first?.id == droppedID else {
        throw DockError.storageFailure("Vague-impression Recall did not retrieve Deep item")
    }

    guard vm.resurfaceFromRecall(id: droppedID)?.status == .docked, vm.snapshot.berths.count == 1 else {
        throw DockError.storageFailure("Resurface from Recall did not restore Berth")
    }

    // 3. Verify SystemShiftMonitor responds to screen lock/unlock and sleep/wake notifications cleanly
    let fakeDistributed = NotificationCenter()
    let fakeWorkspace = NotificationCenter()
    let monitor = SystemShiftMonitor(
        distributedCenter: fakeDistributed,
        workspaceCenter: fakeWorkspace,
        syncInterval: 60.0,
        onDeparture: { _ in vm.handleSystemDeparture() },
        onArrival: { _ in vm.handleSystemArrival() },
        onPeriodicSync: { vm.syncMobileBridgeInBackground() }
    )
    monitor.start()
    fakeDistributed.post(name: SystemShiftMonitor.screenIsLockedNotification, object: nil)
    guard vm.snapshot.activeLane == .life, !monitor.isAwakeAndUnlocked else {
        throw DockError.storageFailure("SystemShiftMonitor failed to shift to Life on screenIsLocked")
    }
    fakeWorkspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    guard vm.snapshot.activeLane == .work, monitor.isAwakeAndUnlocked else {
        throw DockError.storageFailure("SystemShiftMonitor failed to shift to Work on didWake")
    }
    monitor.stop()
    guard !monitor.isRunning else {
        throw DockError.storageFailure("SystemShiftMonitor failed to stop cleanly")
    }

    // 4. Verify SettingsViewModel saves 0600 config & hot-reloads into DockViewModel without restart
    let settingsVM = SettingsViewModel(store: smokeStore, dockViewModel: vm)
    settingsVM.draft.llmBaseURL = "https://api.deepseek.com/v1"
    settingsVM.draft.llmModel = "deepseek-chat"
    settingsVM.draft.llmAPIKey = "sk-smoke-test-key"
    guard settingsVM.saveAndApply(),
          smokeStore.load().llmAPIKey == "sk-smoke-test-key" else {
        throw DockError.storageFailure("SettingsViewModel failed to persist and hot-reload settings")
    }

    print("MindDockApp smoke check passed (Voice on-demand teardown, Prep ready, Recall & Resurface, SystemShiftMonitor, Settings hot-reload verified)")
}

if CommandLine.arguments.contains("--smoke-check") {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var smokeError: Error?
    Task { @MainActor in
        do {
            try await runSmokeCheck()
        } catch {
            smokeError = error
        }
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.01) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    if let smokeError {
        fputs("Smoke check error: \(smokeError)\n", stderr)
        Foundation.exit(1)
    }
    Foundation.exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = MindDockAppDelegate()
    app.delegate = delegate
    app.run()
}
