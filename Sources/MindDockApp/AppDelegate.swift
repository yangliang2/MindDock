import AppKit
import MindDockCore
import SwiftUI

@MainActor
final class FocusTriggerModel: ObservableObject {
    @Published var token: Int = 0
}

@MainActor
final class MindDockAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsStore = MindDockSettingsStore()
    private var viewModel: DockViewModel?
    private var settingsViewModel: SettingsViewModel?
    private var edgeDockPanel: EdgeDockPanel?
    private var quickDropPanel: QuickDropPanel?
    private var settingsWindow: SettingsWindow?
    private var shiftMonitor: SystemShiftMonitor?
    private let focusTrigger = FocusTriggerModel()
    private weak var previousExternalApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupApplicationMainMenu()

        do {
            let initialSettings = settingsStore.load()
            let engine = try DockEngine(
                databasePath: DockEngine.defaultDatabasePath(),
                settings: initialSettings
            )
            let vm = try DockViewModel(
                engine: engine,
                settingsStore: settingsStore,
                initialSettings: initialSettings
            )
            self.viewModel = vm

            setupPanels(with: vm)
            setupStatusItem(with: vm)
            setupHotKeys()
            setupSystemShiftMonitor(with: vm)

            vm.onStateChanged = { [weak self] in
                self?.updateStatusItemAppearance()
            }

            showEdgeDock()
            vm.syncMobileBridgeInBackground()
        } catch {
            fputs("Failed to launch MindDock: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.cancelQuickBarSession()
        shiftMonitor?.stop()
        HotKeyManager.shared.unregisterAll()
    }

    // MARK: - Setup

    private func setupPanels(with vm: DockViewModel) {
        let edgeView = EdgeDockView(
            viewModel: vm,
            onOpenQuickDrop: { [weak self] in self?.showQuickDrop(mode: .drop) },
            onOpenRecall: { [weak self] in self?.showQuickDrop(mode: .recall) },
            onOpenSettings: { [weak self] in self?.showSettingsWindow() },
            onHideDock: { [weak self] in self?.hideEdgeDock() }
        )
        self.edgeDockPanel = EdgeDockPanel(rootView: edgeView)

        let quickDropHost = QuickDropContainerView(
            viewModel: vm,
            focusTrigger: focusTrigger,
            onSubmitted: { [weak self] in self?.dismissQuickDropAndRestoreFocus() },
            onCancelled: { [weak self] in self?.dismissQuickDropAndRestoreFocus() }
        )
        let quickPanel = QuickDropPanel(rootView: quickDropHost)
        quickPanel.onCancel = { [weak self] in
            self?.dismissQuickDropAndRestoreFocus()
        }
        quickPanel.onDidResignKey = { [weak self] in
            self?.viewModel?.stopVoiceCapture()
        }
        self.quickDropPanel = quickPanel
    }

    private func setupStatusItem(with vm: DockViewModel) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item
        updateStatusItemAppearance()

        let menu = NSMenu()

        let quickDropItem = NSMenuItem(
            title: "Quick Drop… (⌥Space)",
            action: #selector(handleQuickDropMenu),
            keyEquivalent: ""
        )
        quickDropItem.target = self
        menu.addItem(quickDropItem)

        let recallItem = NSMenuItem(
            title: "Recall from Deep…",
            action: #selector(handleRecallMenu),
            keyEquivalent: ""
        )
        recallItem.target = self
        menu.addItem(recallItem)

        let toggleDockItem = NSMenuItem(
            title: "Toggle Edge Dock (⌥⇧Space)",
            action: #selector(handleToggleEdgeDockMenu),
            keyEquivalent: ""
        )
        toggleDockItem.target = self
        menu.addItem(toggleDockItem)

        menu.addItem(.separator())

        let shiftWorkItem = NSMenuItem(
            title: "Shift to Work Dock",
            action: #selector(handleShiftWork),
            keyEquivalent: ""
        )
        shiftWorkItem.target = self
        menu.addItem(shiftWorkItem)

        let shiftLifeItem = NSMenuItem(
            title: "Shift to Life Dock",
            action: #selector(handleShiftLife),
            keyEquivalent: ""
        )
        shiftLifeItem.target = self
        menu.addItem(shiftLifeItem)

        let syncMobileItem = NSMenuItem(
            title: "Sync Mobile Drops Now",
            action: #selector(handleSyncMobileNow),
            keyEquivalent: ""
        )
        syncMobileItem.target = self
        menu.addItem(syncMobileItem)

        let testPushItem = NSMenuItem(
            title: "Test Lock-Screen Push",
            action: #selector(handleTestLockScreenPush),
            keyEquivalent: ""
        )
        testPushItem.target = self
        menu.addItem(testPushItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings & Mobile Setup…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "Quit MindDock",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    private func setupHotKeys() {
        HotKeyManager.shared.onQuickDrop = { [weak self] in
            self?.toggleQuickDrop()
        }
        HotKeyManager.shared.onToggleEdgeDock = { [weak self] in
            self?.toggleEdgeDock()
        }
        HotKeyManager.shared.registerDefaultHotKeys()
    }

    private func setupSystemShiftMonitor(with vm: DockViewModel) {
        let monitor = SystemShiftMonitor(
            onDeparture: { [weak vm] _ in
                vm?.handleSystemDeparture()
            },
            onArrival: { [weak vm] _ in
                vm?.handleSystemArrival()
            },
            onPeriodicSync: { [weak vm] in
                vm?.syncMobileBridgeInBackground()
            }
        )
        monitor.start()
        self.shiftMonitor = monitor
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button, let vm = viewModel else { return }
        let snap = vm.snapshot
        let symbolName = snap.lane == .work ? "ferry.fill" : "leaf.fill"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MindDock") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
        button.title = " \(snap.berths.count)/\(DockEngine.maxBerths)"
    }

    // MARK: - Panel Visibility & Non-Intrusive Focus Management

    func toggleEdgeDock() {
        guard let panel = edgeDockPanel else { return }
        if panel.isVisible {
            hideEdgeDock()
        } else {
            showEdgeDock()
        }
    }

    func showEdgeDock() {
        guard let panel = edgeDockPanel else { return }
        viewModel?.refresh()
        panel.positionAtRightScreenEdge()
        panel.orderFrontRegardless()
    }

    func hideEdgeDock() {
        edgeDockPanel?.orderOut(nil)
    }

    func toggleQuickDrop() {
        guard let panel = quickDropPanel else { return }
        if panel.isVisible && panel.isKeyWindow {
            dismissQuickDropAndRestoreFocus()
        } else {
            showQuickDrop(mode: .drop)
        }
    }

    func showQuickDrop(mode: QuickBarMode = .drop) {
        guard let panel = quickDropPanel else { return }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousExternalApp = frontmost
        }
        viewModel?.setQuickBarMode(mode)
        panel.centerNearUpperThird()
        focusTrigger.token &+= 1
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissQuickDropAndRestoreFocus() {
        viewModel?.cancelQuickBarSession()
        quickDropPanel?.orderOut(nil)
        if let previousExternalApp, !previousExternalApp.isTerminated {
            previousExternalApp.activate()
        }
        self.previousExternalApp = nil
    }

    func showSettingsWindow() {
        guard let vm = viewModel else { return }
        if settingsWindow == nil {
            let settingsVM = SettingsViewModel(store: settingsStore, dockViewModel: vm)
            self.settingsViewModel = settingsVM
            let rootView = SettingsView(
                viewModel: settingsVM,
                onClose: { [weak self] in
                    self?.settingsWindow?.close()
                }
            )
            self.settingsWindow = SettingsWindow(rootView: rootView)
        } else {
            settingsViewModel?.draft = settingsStore.load()
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func setupApplicationMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings & Mobile Setup…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit MindDock",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Standard Edit menu enables ⌘V / ⌘C / ⌘X / ⌘A / ⌘Z inside accessory-app TextFields & SecureFields
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

    @objc private func handleQuickDropMenu() {
        showQuickDrop(mode: .drop)
    }

    @objc private func handleRecallMenu() {
        showQuickDrop(mode: .recall)
    }

    @objc private func handleToggleEdgeDockMenu() {
        toggleEdgeDock()
    }

    @objc private func handleShiftWork() {
        viewModel?.shift(to: .work)
        showEdgeDock()
    }

    @objc private func handleShiftLife() {
        viewModel?.shift(to: .life)
        showEdgeDock()
    }

    @objc private func handleSyncMobileNow() {
        viewModel?.syncMobileBridgeInBackground(manual: true)
    }

    @objc private func handleTestLockScreenPush() {
        guard let vm = viewModel else { return }
        Task { @MainActor in
            do {
                _ = try await vm.triggerTestMobilePush()
                self.showEdgeDock()
            } catch {
                vm.statusBanner = "Test push failed: \(error.localizedDescription)"
                self.showSettingsWindow()
            }
        }
    }

    @objc private func handleOpenSettings() {
        showSettingsWindow()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}

private struct QuickDropContainerView: View {
    @ObservedObject var viewModel: DockViewModel
    @ObservedObject var focusTrigger: FocusTriggerModel
    let onSubmitted: () -> Void
    let onCancelled: () -> Void

    var body: some View {
        QuickDropBarView(
            viewModel: viewModel,
            focusTrigger: focusTrigger.token,
            onSubmitted: onSubmitted,
            onCancelled: onCancelled
        )
    }
}
