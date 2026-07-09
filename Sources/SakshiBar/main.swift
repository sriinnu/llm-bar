import AppKit
import Darwin
import SwiftUI
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    let state = AppState()

    // Sparkle: startingUpdater true polls on launch + every 24h per Info.plist's
    // SUScheduledCheckInterval. updaterDelegate/userDriverDelegate nil = defaults.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            // Bundle.main finds Contents/Resources/icon.svg in the packaged .app
            // (bundle.sh copies it there). Bundle.module is the SPM-resource-bundle
            // fallback for `swift run` during development, where there's no
            // Contents/Resources — only used when Bundle.main comes up empty.
            let icon = (Bundle.main.url(forResource: "icon", withExtension: "svg")
                ?? Bundle.module.url(forResource: "icon", withExtension: "svg"))
                .flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(systemSymbolName: "cpu", accessibilityDescription: "Sakshi")
            icon?.isTemplate = false  // keep the gradient — don't let the menu bar flatten it to monochrome
            icon?.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(state: state, updaterController: updaterController, onQuit: {
                NSApplication.shared.terminate(nil)
            })
        )
    }

    @objc func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            state.startPolling()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        state.stopPolling()
    }
}

// main.swift's top level runs on the main thread before any concurrency has
// started, so this is genuinely main-actor-isolated — assumeIsolated tells
// the compiler that without needing async/await ceremony for a plain
// synchronous app entry point.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
