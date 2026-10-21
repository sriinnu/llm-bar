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


    func shows(group: String) -> Bool {
        let g = group.lowercased()
        if g.contains("cheap") { return showCheap }
        if g.contains("free") { return showFree }
        return showPaid
    }

    func resetAll() {
        objectWillChange.send()
        for k in ["lcpDir","lcpServer","lcpPidfile","hfCache","ollamaHost","claudeConfig","laneStatus","laneProbe","koshaRegistry","terminal",
                  "showPaid","showCheap","showFree","showPricing","probeHour","compact","tinted"] {
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "LLM Bar Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: AppSettings.shared, state: state))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let state: AppState
    @State private var agentMessage = ""
    @State private var koshaBusy = false
    @State private var koshaMessage = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Local models") {
                pathField("llama.cpp models dir", AppSettings.lcpDir)
                pathField("llama-server binary", AppSettings.lcpServer)
                pathField("llama-server pidfile", AppSettings.lcpPidfile)
                pathField("Hugging Face cache", AppSettings.hfCache)
                pathField("Ollama API host", AppSettings.ollamaHost)
            }
            Section("Cloud lanes") {
                pathField("Claude Code config (lane list)", AppSettings.claudeConfig)
                pathField("Lane status cache", AppSettings.laneStatus)
                pathField("Probe script (blank = next to config)", AppSettings.laneProbe)
                Picker("Open lanes in", selection: Binding(
                    get: { settings.string(AppSettings.terminal) },
                    set: { settings.set(AppSettings.terminal, $0) })) {
                    Text("Ghostty").tag("Ghostty")
                    Text("Terminal.app").tag("Terminal")
                }
                Toggle("Show paid lanes", isOn: Binding(get: { settings.showPaid }, set: { settings.showPaid = $0 }))
                Toggle("Show cheap OpenRouter lanes", isOn: Binding(get: { settings.showCheap }, set: { settings.showCheap = $0 }))
                Toggle("Show free-tier lanes", isOn: Binding(get: { settings.showFree }, set: { settings.showFree = $0 }))
            }
            Section("Pricing (kosha)") {
                pathField("kosha registry", AppSettings.koshaRegistry)
                Toggle("Show model price under each lane", isOn: Binding(get: { settings.showPricing }, set: { settings.showPricing = $0 }))
                HStack(spacing: 8) {
                    Text(koshaMessage.isEmpty ? KoshaRegistry.shared.summary : koshaMessage)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if koshaBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: {
                            koshaBusy = true
                            koshaMessage = "running kosha update + enrich…"
                            runKoshaUpdate { ok, msg in
                                koshaBusy = false
                                koshaMessage = (ok ? "✓ " : "✗ ") + msg
                                state.refresh()
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Run `kosha update` then `kosha enrich` (re-discover providers, refresh prices)")
                    }
                }
            }
            Section("Look") {
                Toggle("Compact rows (no descriptions or prices)", isOn: Binding(get: { settings.compact }, set: { settings.compact = $0 }))
                Toggle("Tinted section headers", isOn: Binding(get: { settings.tinted }, set: { settings.tinted = $0 }))
            }
            Section("App") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        } catch {
                            agentMessage = "launch at login: \(error.localizedDescription)"
                        }
                    }))
            }
            Section("Daily probe (launchd)") {
                Stepper("Run at \(String(format: "%02d:00", settings.probeHour)) and at login",
                        value: Binding(get: { settings.probeHour }, set: { settings.probeHour = $0 }), in: 0...23)
                HStack {
                    Button(laneProbeAgentInstalled() ? "Reinstall agent" : "Install agent") {
                        agentMessage = installLaneProbeAgent(hour: settings.probeHour) ?? "installed: \(LANE_PROBE_LAUNCHD_LABEL)"
                        state.refresh()
                    }
                    if laneProbeAgentInstalled() {
                        Button("Remove agent") { removeLaneProbeAgent(); agentMessage = "removed"; state.refresh() }
                    }
                    Button("Probe now") { state.refreshLanes(); agentMessage = "probing…" }
                }
                if !agentMessage.isEmpty {
                    Text(agentMessage).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("Reset to defaults") { settings.resetAll(); state.refresh() }
                    Spacer()
                    Text("Environment variables (LLMBAR_*) override these.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onDisappear { state.refresh() }
    }

    @ViewBuilder
    private func pathField(_ label: String, _ key: AppSettings.Key) -> some View {
        let overridden = settings.isEnvOverridden(key)
        TextField(label, text: Binding(
            get: { settings.string(key) },
            set: { settings.set(key, $0) }))
            .disabled(overridden)
            .help(overridden ? "Set by \(key.env) in the environment" : "Default: \(key.fallback)")
            .font(.system(size: 11, design: .monospaced))
    }
}
