import SwiftUI
import AppKit

@main
struct _02rapi: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 320, height: 200)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Restore Default") {
                    NotificationCenter.default.post(name: .restoreDefaults, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Always on Top") {
                    NotificationCenter.default.post(name: .toggleOnTop, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Toggle Glass Effect") {
                    NotificationCenter.default.post(name: .toggleGlassEffect, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var didSetup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first else { return }
            window.delegate = self
            self.applyStyle(window)
            window.setContentSize(NSSize(width: 320, height: 200))
            self.didSetup = true
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            applyStyle(window)
        }
    }

    private func applyStyle(_ window: NSWindow) {
        window.styleMask = [.borderless, .fullSizeContentView]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 32
            contentView.layer?.masksToBounds = true
            contentView.layer?.backgroundColor = .clear
        }
    }
}
