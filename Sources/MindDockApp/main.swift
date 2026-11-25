import AppKit
import Foundation
import MindDockCore

@MainActor
private func runSmokeCheck() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindDockSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let engine = try DockEngine(databasePath: tempDir.appendingPathComponent("smoke.sqlite3").path)
    let vm = try DockViewModel(engine: engine)
    vm.draftText = "Smoke test Drop"
    guard vm.submitDraftDrop(), vm.snapshot.berths.count == 1 else {
        throw DockError.storageFailure("MindDockApp smoke check failed")
    }

    // Verify SystemShiftMonitor responds to screen lock/unlock and sleep/wake notifications cleanly
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

    print("MindDockApp smoke check passed (1/3 Berths active, SystemShiftMonitor verified)")
}

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--smoke-check") {
        do {
            try runSmokeCheck()
            Foundation.exit(0)
        } catch {
            fputs("Smoke check error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    let app = NSApplication.shared
    let delegate = MindDockAppDelegate()
    app.delegate = delegate
    app.run()
}
