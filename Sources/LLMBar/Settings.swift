import AppKit
import Foundation
import ServiceManagement
import SwiftUI

// User settings. Resolution order for every path: environment variable (power users,
// scripts) > UserDefaults (the Settings window) > built-in default. Env wins so a
// one-off `LLMBAR_LCP_DIR=… ./LLMBar` still behaves as documented.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    struct Key {
        let name: String        // UserDefaults key
        let env: String         // environment override
        let fallback: String
    }

    static let lcpDir       = Key(name: "lcpDir",       env: "LLMBAR_LCP_DIR",        fallback: NSHomeDirectory() + "/llama-cpp-setup/models")
    static let lcpServer    = Key(name: "lcpServer",    env: "LLMBAR_LCP_SERVER",     fallback: NSHomeDirectory() + "/.local/bin/llama-server")
    static let lcpPidfile   = Key(name: "lcpPidfile",   env: "LLMBAR_LCP_PIDFILE",    fallback: NSHomeDirectory() + "/.cache/lcp/llama-server.pid")
    static let hfCache      = Key(name: "hfCache",      env: "LLMBAR_HF_CACHE_DIR",   fallback: NSHomeDirectory() + "/.cache/huggingface/hub")
    static let ollamaHost   = Key(name: "ollamaHost",   env: "LLMBAR_OLLAMA_HOST",    fallback: "http://127.0.0.1:11434")
    static let claudeConfig = Key(name: "claudeConfig", env: "LLMBAR_CLAUDE_CONFIG",  fallback: NSHomeDirectory() + "/.claude_config.zsh")
    static let laneStatus   = Key(name: "laneStatus",   env: "LLMBAR_LANE_STATUS",    fallback: NSHomeDirectory() + "/.cache/lcp/lane-status.json")
    static let laneProbe    = Key(name: "laneProbe",    env: "LLMBAR_LANE_PROBE",     fallback: "")   // "" = next to the resolved config
    static let koshaRegistry = Key(name: "koshaRegistry", env: "LLMBAR_KOSHA_REGISTRY", fallback: NSHomeDirectory() + "/.kosha/registry.json")
    static let terminal     = Key(name: "terminal",     env: "LLMBAR_TERMINAL",       fallback: "Ghostty")
    static let wtrScript    = Key(name: "wtrScript",    env: "LLMBAR_WTR",            fallback: NSHomeDirectory() + "/.agents/skills/worktree-task-retirement/scripts/wtr.py")
    static let wtrScanRoots = Key(name: "wtrScanRoots", env: "LLMBAR_WTR_SCAN",       fallback: "")   // "" = only what the skill discovers from your agents' worktrees

    func string(_ k: Key) -> String {
        if let e = ProcessInfo.processInfo.environment[k.env], !e.isEmpty { return e }
        if let v = d.string(forKey: k.name), !v.isEmpty { return v }
        if k.name == Self.lcpDir.name, let fromConfig = Self.lcpDirFromConfig() { return fromConfig }
        return k.fallback
    }

    /// The `lcp` shell function keeps its models dir in claude_config.zsh as
    /// `_LCP_MODELS_DIR="${LCP_MODELS_DIR:-$HOME/Models/gguf}"`. Reuse it so the app and the CLI
    /// agree without the user configuring the same path twice.
    static func lcpDirFromConfig() -> String? {
        let cfg = AppSettings.shared.string(AppSettings.claudeConfig)
        guard let text = try? String(contentsOfFile: cfg, encoding: .utf8) else { return nil }
        let re = try! NSRegularExpression(pattern: #"_LCP_MODELS_DIR="\$\{LCP_MODELS_DIR:-([^}"]+)\}""#)
        let r = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: r), let g = Range(m.range(at: 1), in: text) else { return nil }
        let raw = String(text[g])
        let expanded = raw.replacingOccurrences(of: "$HOME", with: NSHomeDirectory()).replacingOccurrences(of: "${HOME}", with: NSHomeDirectory())
        return expanded.hasPrefix("~") ? NSHomeDirectory() + expanded.dropFirst() : expanded
    }
    func isEnvOverridden(_ k: Key) -> Bool {
        !(ProcessInfo.processInfo.environment[k.env] ?? "").isEmpty
    }
    func set(_ k: Key, _ value: String) {
        objectWillChange.send()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == k.fallback { d.removeObject(forKey: k.name) } else { d.set(trimmed, forKey: k.name) }
    }

    // Lane groups shown in the Cloud lanes card (lcp-help section headers).
    var showPaid: Bool  { get { d.object(forKey: "showPaid")  as? Bool ?? true } set { objectWillChange.send(); d.set(newValue, forKey: "showPaid") } }
    var showCheap: Bool { get { d.object(forKey: "showCheap") as? Bool ?? true } set { objectWillChange.send(); d.set(newValue, forKey: "showCheap") } }
    var showFree: Bool  { get { d.object(forKey: "showFree")  as? Bool ?? true } set { objectWillChange.send(); d.set(newValue, forKey: "showFree") } }
    var showPricing: Bool { get { d.object(forKey: "showPricing") as? Bool ?? true } set { objectWillChange.send(); d.set(newValue, forKey: "showPricing") } }
    var probeHour: Int  { get { d.object(forKey: "probeHour") as? Int ?? 7 } set { objectWillChange.send(); d.set(newValue, forKey: "probeHour") } }
    // Look: two independent switches on the native list. Compact = tighter rows, no lane
    // descriptions or price lines. Tinted = section headers take their badge colour.
    var compact: Bool { get { d.object(forKey: "compact") as? Bool ?? false } set { objectWillChange.send(); d.set(newValue, forKey: "compact") } }
    var tinted: Bool  { get { d.object(forKey: "tinted")  as? Bool ?? false } set { objectWillChange.send(); d.set(newValue, forKey: "tinted") } }
    // Look + navigation.
    var theme: ThemeID { get { ThemeID(rawValue: d.string(forKey: "theme") ?? "") ?? .native } set { objectWillChange.send(); d.set(newValue.rawValue, forKey: "theme") } }
    var lastTab: String { get { d.string(forKey: "lastTab") ?? "worktrees" } set { objectWillChange.send(); d.set(newValue, forKey: "lastTab") } }
    /// Show Jev's advisory suggestion on worktrees (when the skill has recorded one).
    var showAdvice: Bool { get { d.object(forKey: "showAdvice") as? Bool ?? true } set { objectWillChange.send(); d.set(newValue, forKey: "showAdvice") } }
    /// How worktree lists group: "project", "agent" or "none".
    var worktreeGroup: String { get { d.string(forKey: "worktreeGroup") ?? "project" } set { objectWillChange.send(); d.set(newValue, forKey: "worktreeGroup") } }
    var worktreeView: String { get { d.string(forKey: "worktreeView") ?? "lifecycle" } set { objectWillChange.send(); d.set(newValue, forKey: "worktreeView") } }
    // Worktrees section.
    var showWorktrees: Bool { get { d.object(forKey: "showWorktrees") as? Bool ?? true } set { objectWillChange.send(); d.set(newValue, forKey: "showWorktrees") } }
    /// Minutes between background refreshes of the fast listing (stats). Sizes + audit run every 6th refresh.
    var worktreeRefreshMinutes: Int { get { d.object(forKey: "worktreeRefreshMinutes") as? Int ?? 10 } set { objectWillChange.send(); d.set(newValue, forKey: "worktreeRefreshMinutes") } }
    /// Red dot on the menu-bar icon when a worktree is ready to retire or a repo is over its cap.
    var worktreeBadge: Bool { get { d.object(forKey: "worktreeBadge") as? Bool ?? false } set { objectWillChange.send(); d.set(newValue, forKey: "worktreeBadge") } }


    func shows(group: String) -> Bool {
        let g = group.lowercased()
        if g.contains("cheap") { return showCheap }
        if g.contains("free") { return showFree }
        return showPaid
    }

    func resetAll() {
        objectWillChange.send()
        for k in ["lcpDir","lcpServer","lcpPidfile","hfCache","ollamaHost","claudeConfig","laneStatus","laneProbe","koshaRegistry","terminal",
                  "showPaid","showCheap","showFree","showPricing","probeHour","compact","tinted",
                  "wtrScript","wtrScanRoots","showWorktrees","worktreeRefreshMinutes","worktreeBadge",
                  "theme","lastTab","worktreeView","worktreeGroup","showAdvice"] {
            d.removeObject(forKey: k)
        }
    }
}

// MARK: - launchd agent for the daily probe

let LANE_PROBE_LAUNCHD_LABEL = "com.sriinnu.lane-status"

func laneProbePlistPath() -> String {
    NSHomeDirectory() + "/Library/LaunchAgents/\(LANE_PROBE_LAUNCHD_LABEL).plist"
}

func laneProbeAgentInstalled() -> Bool {
    FileManager.default.fileExists(atPath: laneProbePlistPath())
}

/// Writes the agent plist (daily at `hour`:00 + at login) and (re)loads it. Returns an error string on failure.
func installLaneProbeAgent(hour: Int) -> String? {
    let probe = LANE_PROBE_PATH
    guard FileManager.default.isReadableFile(atPath: probe) else { return "probe script not found: \(probe)" }
    let log = NSHomeDirectory() + "/.cache/lcp/lane-status.log"
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(LANE_PROBE_LAUNCHD_LABEL)</string>
        <key>ProgramArguments</key><array><string>/bin/zsh</string><string>\(probe)</string></array>
        <key>RunAtLoad</key><true/>
        <key>StartCalendarInterval</key><dict><key>Hour</key><integer>\(hour)</integer><key>Minute</key><integer>0</integer></dict>
        <key>StandardOutPath</key><string>\(log)</string>
        <key>StandardErrorPath</key><string>\(log)</string>
    </dict>
    </plist>
    """
    let path = laneProbePlistPath()
    do {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try plist.write(toFile: path, atomically: true, encoding: .utf8)
    } catch { return error.localizedDescription }
    let uid = getuid()
    _ = runLaunchctl(["bootout", "gui/\(uid)/\(LANE_PROBE_LAUNCHD_LABEL)"])
    let (code, out) = runLaunchctl(["bootstrap", "gui/\(uid)", path])
    return code == 0 ? nil : "launchctl bootstrap failed: \(out)"
}

func removeLaneProbeAgent() {
    _ = runLaunchctl(["bootout", "gui/\(getuid())/\(LANE_PROBE_LAUNCHD_LABEL)"])
    try? FileManager.default.removeItem(atPath: laneProbePlistPath())
}

private func runLaunchctl(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (1, error.localizedDescription) }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Windows (About, Settings) for a menu-bar-only app

@MainActor
enum AppWindows {
    private static var settingsWindow: NSWindow?

    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.paragraphStyle: para, .font: NSFont.systemFont(ofSize: 12)]
        let credits = NSMutableAttributedString(string: "Every model you can reach, in the menu bar.\n\n", attributes: base)
        var link = base
        link[.link] = URL(string: "https://github.com/sriinnu/llm-bar")!
        credits.append(NSAttributedString(string: "github.com/sriinnu/llm-bar", attributes: link))
        credits.append(NSAttributedString(string: "\nMIT licence", attributes: base))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "LLM Bar",
            .credits: credits,
        ])
    }

    static func showSettings(state: AppState) {
        if settingsWindow == nil {
            // A sidebar settings window (System Settings style): full-size content under a unified
            // toolbar so the sidebar gets its translucent material.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "LLM Bar Settings"
            w.toolbar = NSToolbar(identifier: "settings")
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 700, height: 480)
            w.contentView = NSHostingView(rootView: SettingsView(settings: AppSettings.shared, state: state))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
