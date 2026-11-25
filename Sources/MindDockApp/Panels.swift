import AppKit
import SwiftUI

@MainActor
final class EdgeDockPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        let initialRect = NSRect(x: 0, y: 0, width: 320, height: 500)
        super.init(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.frame = initialRect
        contentView = hosting

        positionAtRightScreenEdge()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func positionAtRightScreenEdge() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 14
        let originX = visible.maxX - frame.width - margin
        let originY = visible.midY - (frame.height / 2)
        setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

@MainActor
final class QuickDropPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onDidResignKey: (() -> Void)?

    init<Content: View>(rootView: Content) {
        let initialRect = NSRect(x: 0, y: 0, width: 560, height: 132)
        super.init(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.frame = initialRect
        contentView = hosting

        centerNearUpperThird()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onDidResignKey?()
    }

    func centerNearUpperThird() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let originX = visible.midX - (frame.width / 2)
        let originY = visible.minY + (visible.height * 0.65)
        setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
