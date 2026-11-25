import AppKit
import SwiftUI
import MindDockCore

@MainActor
final class FocusTriggerModel: ObservableObject {
    @Published var token: Int = 0
}

@MainActor
final class MindDockAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var viewModel: DockViewModel?
    private var edgeDockPanel: EdgeDockPanel?
    private var quickDropPanel: QuickDropPanel?
    private let focusTrigger = FocusTriggerModel()
    private weak var previousExternalApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let engine = try DockEngine(databasePath: DockEngine.defaultDatabasePath())
            let vm = try DockViewModel(engine: engine)
            self.viewModel = vm

            setupPanels(with: vm)
            setupStatusItem(with: vm)
            setupHotKeys()

            vm.onStateChanged = { [weak self] in
                self?.updateStatusItemAppearance()
            }

            showEdgeDock()
        } catch {
            fputs("Failed to launch MindDock: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregisterAll()
    }

    // MARK: - Setup

    private func setupPanels(with vm: DockViewModel) {
        let edgeView = EdgeDockView(
            viewModel: vm,
            onOpenQuickDrop: { [weak self] in self?.showQuickDrop() },
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

        menu.addItem(.separator())

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
            showQuickDrop()
        }
    }

    func showQuickDrop() {
        guard let panel = quickDropPanel else { return }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousExternalApp = frontmost
        }
        panel.centerNearUpperThird()
        focusTrigger.token &+= 1
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissQuickDropAndRestoreFocus() {
        quickDropPanel?.orderOut(nil)
        if let previousExternalApp, !previousExternalApp.isTerminated {
            previousExternalApp.activate()
        }
        self.previousExternalApp = nil
    }

    // MARK: - Menu Actions

    @objc private func handleQuickDropMenu() {
        showQuickDrop()
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
