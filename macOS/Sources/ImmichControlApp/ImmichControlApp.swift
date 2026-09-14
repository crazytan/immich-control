import AppKit
import SwiftUI

@main
struct ImmichControlApp: App {
    @NSApplicationDelegateAdaptor(ImmichControlAppDelegate.self) private var appDelegate
    @StateObject private var controller: ImmichAppController

    init() {
        let demoMode = ProcessInfo.processInfo.arguments.contains("--demo")
        let controller = ImmichAppController(demoMode: demoMode)
        _controller = StateObject(wrappedValue: controller)
        appDelegate.configure(with: controller)
    }

    var body: some Scene {
        MenuBarExtra("Immich Control", systemImage: controller.menuSymbolName) {
            MenuPopoverView(controller: controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ImmichSettingsView(controller: controller)
        }
    }
}

private final class ImmichControlAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ImmichAppController?
    private var previewWindow: NSWindow?
    private var didFinishLaunching = false

    func configure(with controller: ImmichAppController) {
        self.controller = controller
        if didFinishLaunching { showDemoWindowIfNeeded() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        showDemoWindowIfNeeded()
    }

    private func showDemoWindowIfNeeded() {
        guard let controller, controller.isDemoMode, previewWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Immich Control Preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DemoPreviewWindow(controller: controller))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
    }
}

private struct DemoPreviewWindow: View {
    @ObservedObject var controller: ImmichAppController

    var body: some View {
        MenuPopoverView(controller: controller)
            .frame(minWidth: 360)
    }
}
