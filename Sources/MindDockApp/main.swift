import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = MindDockAppDelegate()
    app.delegate = delegate
    app.run()
}
