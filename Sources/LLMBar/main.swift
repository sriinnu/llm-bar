import AppKit
import Combine
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
    private var settingsSink: AnyCancellable?
    private var appliedTheme: ThemeID?

    /// Hot-reload: the popover's own chrome (material, arrow) follows the theme's scheme the
    /// moment it changes in Settings; SwiftUI content re-renders on its own.
    func applyThemeChrome() {
        let id = AppSettings.shared.theme
        guard id != appliedTheme else { return }
        appliedTheme = id
        switch Theme.of(id).scheme {
        case .some(.dark): popover.appearance = NSAppearance(named: .darkAqua)
        case .some(.light): popover.appearance = NSAppearance(named: .aqua)
        default: popover.appearance = nil   // follow the system
        }
    }
    private var badgeTimer: Timer?

    /// Base icon, plus a small red dot when any shown lane needs attention.
    func updateStatusIcon() {
        guard let button = statusItem.button, let base = baseIcon else { return }
        let n = state.laneAttentionCount
        let ready = AppSettings.shared.worktreeBadge ? state.worktreeReadyCount : 0
        if n == 0 && ready == 0 {
            button.image = base
            button.toolTip = "LLM Bar"
            return
        }
        // A coloured badge can't live in a template image, so draw the glyph in the menu bar's own
        // text colour (resolved at draw time, so it follows light/dark) and add the red dot.
        let size = base.size
        let img = NSImage(size: size, flipped: false) { rect in
            let tinted = NSImage(size: size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
            let d: CGFloat = 6.5
            let dot = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: dot).fill()
            return true
        }
        img.isTemplate = false
        button.image = img
        var reasons: [String] = []
        if n > 0 { reasons.append("\(n) lane\(n == 1 ? "" : "s") need attention") }
        if ready > 0 { reasons.append("\(ready) worktree\(ready == 1 ? "" : "s") ready to retire") }
        button.toolTip = "LLM Bar — " + reasons.joined(separator: ", ")
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
            icon?.isTemplate = true   // HIG: menu bar extras are template images, tinted by the system
            icon?.size = NSSize(width: 18, height: 18)
            baseIcon = icon
            button.image = icon
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Badge: read the status cache now and every 10 minutes (file read only, no network),
        // and whenever a probe finishes.
        state.onLaneStatusChanged = { [weak self] in self?.updateStatusIcon() }
        state.onWorktreesChanged = { [weak self] in self?.updateStatusIcon() }
        state.restartWorktreeTimer()
        state.reloadLaneStatus()
        updateStatusIcon()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.state.reloadLaneStatus()
                self?.updateStatusIcon()
            }
        }

        applyThemeChrome()
        settingsSink = AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)   // objectWillChange fires before the value is stored
            .sink { [weak self] _ in self?.applyThemeChrome() }
        popover.behavior = .transient   // any click outside closes it
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
            state.refreshWorktreesIfStale()
            NSApp.activate(ignoringOtherApps: true)   // so the system sees the next click as "outside"
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Belt and braces: an accessory app's transient popover can miss clicks in other apps.
            // A global monitor only sees events in OTHER apps or the desktop, i.e. outside clicks.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.popover.performClose(nil) }
            }
        }
    }

    private var outsideClickMonitor: Any?

    func popoverDidClose(_ notification: Notification) {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        state.stopPolling()
        updateStatusIcon()
    }
}

// main.swift's top level runs on the main thread before any concurrency has
// started, so this is genuinely main-actor-isolated — assumeIsolated tells
// the compiler that without needing async/await ceremony for a plain
// synchronous app entry point.
MainActor.assumeIsolated {
    // Dev aid: `LLMBar --snapshot-worktrees rows.json out.png [dark]` renders the Worktrees
    // section from a saved `wtr.py ls --json` listing and exits. No menu-bar item is created.
    let argv = CommandLine.arguments
    if let i = argv.firstIndex(of: "--snapshot-settings"), argv.count > i + 1 {
        exit(snapshotSettings(output: argv[i + 1], options: Array(argv.dropFirst(i + 2))))
    }
    if let i = argv.firstIndex(of: "--snapshot-worktrees"), argv.count > i + 2 {
        exit(snapshotWorktrees(input: argv[i + 1], output: argv[i + 2], options: Array(argv.dropFirst(i + 3))))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
