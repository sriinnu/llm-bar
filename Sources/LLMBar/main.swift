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

    private var baseIcon: NSImage?
    private var badgeTimer: Timer?

    /// Base icon, plus a small red dot when any shown lane needs attention.
    func updateStatusIcon() {
        guard let button = statusItem.button, let base = baseIcon else { return }
        let n = state.laneAttentionCount
        if n == 0 {
            button.image = base
            button.toolTip = "LLM Bar"
            return
        }
        let size = base.size
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let d: CGFloat = 7
            let dot = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
            NSColor.white.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: dot).fill()
            return true
        }
        img.isTemplate = false
        button.image = img
        button.toolTip = "LLM Bar — \(n) lane\(n == 1 ? "" : "s") need attention"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            // Bundle.main finds Contents/Resources/icon.svg in the packaged .app
            // (bundle.sh copies it there). Bundle.module is the SPM-resource-bundle
            // fallback for `swift run` during development, where there's no
            // Contents/Resources — only used when Bundle.main comes up empty.
            let icon = (Bundle.main.url(forResource: "icon", withExtension: "svg")
                ?? Bundle.module.url(forResource: "icon", withExtension: "svg"))
                .flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(systemSymbolName: "cpu", accessibilityDescription: "LLM Bar")
            icon?.isTemplate = false  // keep the gradient — don't let the menu bar flatten it to monochrome
            icon?.size = NSSize(width: 18, height: 18)
            baseIcon = icon
            button.image = icon
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Badge: read the status cache now and every 10 minutes (file read only, no network),
        // and whenever a probe finishes.
        state.onLaneStatusChanged = { [weak self] in self?.updateStatusIcon() }
        state.reloadLaneStatus()
        updateStatusIcon()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.state.reloadLaneStatus()
                self?.updateStatusIcon()
            }
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
        updateStatusIcon()
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
