import AppKit
import Foundation

@MainActor
final class SystemShiftMonitor {
    enum DepartureReason: String, Sendable {
        case screenLocked
        case willSleep
    }

    enum ArrivalReason: String, Sendable {
        case screenUnlocked
        case didWake
    }

    static let screenIsLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenIsUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private let distributedCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let syncInterval: TimeInterval
    private let onDeparture: (DepartureReason) -> Void
    private let onArrival: (ArrivalReason) -> Void
    private let onPeriodicSync: () -> Void

    private var distributedTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var syncTimer: Timer?
    private(set) var isAwakeAndUnlocked: Bool = true
    private(set) var isRunning: Bool = false

    init(
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        syncInterval: TimeInterval = SystemShiftMonitor.defaultSyncInterval(),
        onDeparture: @escaping (DepartureReason) -> Void,
        onArrival: @escaping (ArrivalReason) -> Void,
        onPeriodicSync: @escaping () -> Void
    ) {
        self.distributedCenter = distributedCenter
        self.workspaceCenter = workspaceCenter
        self.syncInterval = syncInterval
        self.onDeparture = onDeparture
        self.onArrival = onArrival
        self.onPeriodicSync = onPeriodicSync
    }

    static func defaultSyncInterval(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        if let raw = environment["MINDDOCK_SYNC_INTERVAL_SECONDS"],
           let parsed = TimeInterval(raw),
           parsed >= 5 {
            return parsed
        }
        return 45.0
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isAwakeAndUnlocked = true

        let lockToken = distributedCenter.addObserver(
            forName: Self.screenIsLockedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDeparture(.screenLocked)
            }
        }

        let unlockToken = distributedCenter.addObserver(
            forName: Self.screenIsUnlockedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleArrival(.screenUnlocked)
            }
        }
        distributedTokens = [lockToken, unlockToken]

        let sleepToken = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDeparture(.willSleep)
            }
        }

        let wakeToken = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleArrival(.didWake)
            }
        }
        workspaceTokens = [sleepToken, wakeToken]

        schedulePeriodicSyncTimerIfNeeded()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        invalidatePeriodicSyncTimer()

        for token in distributedTokens {
            distributedCenter.removeObserver(token)
        }
        distributedTokens.removeAll()

        for token in workspaceTokens {
            workspaceCenter.removeObserver(token)
        }
        workspaceTokens.removeAll()
    }

    private func handleDeparture(_ reason: DepartureReason) {
        isAwakeAndUnlocked = false
        // Immediately stop background timers and hold ZERO sleep wake-locks (no IOPMAssertion).
        invalidatePeriodicSyncTimer()
        onDeparture(reason)
    }

    private func handleArrival(_ reason: ArrivalReason) {
        isAwakeAndUnlocked = true
        schedulePeriodicSyncTimerIfNeeded()
        onArrival(reason)
    }

    private func schedulePeriodicSyncTimerIfNeeded() {
        invalidatePeriodicSyncTimer()
        guard isRunning, isAwakeAndUnlocked, syncInterval > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.isAwakeAndUnlocked else { return }
                self.onPeriodicSync()
            }
        }
        timer.tolerance = max(1.0, syncInterval * 0.2)
        syncTimer = timer
    }

    private func invalidatePeriodicSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
}
