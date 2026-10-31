import AppKit
import ServiceManagement
import SwiftUI

// Settings, laid out the way current macOS does it: a sidebar of panes with coloured icon tiles
// (System Settings style) and a grouped form on the right. Every setting the app had is here;
// the Look pane shows the themes as live previews instead of a dropdown.

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, look, lanes, models, worktrees, advice, pricing, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .look: return "Appearance"
        case .lanes: return "Cloud Lanes"
        case .models: return "Local Models"
        case .worktrees: return "Worktrees"
        case .advice: return "Advice (Jev)"
        case .pricing: return "Pricing"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .look: return "paintbrush.fill"
        case .lanes: return "cloud.fill"
        case .models: return "cpu.fill"
        case .worktrees: return "arrow.triangle.branch"
        case .advice: return "sparkles"
        case .pricing: return "dollarsign"
        case .about: return "info"
        }
    }
    var tile: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .look: return Color(nsColor: .systemPurple)
        case .lanes: return Color(nsColor: .systemBlue)
        case .models: return Color(nsColor: .systemIndigo)
        case .worktrees: return Color(nsColor: .systemGreen)
        case .advice: return Color(nsColor: .systemTeal)
        case .pricing: return Color(nsColor: .systemOrange)
        case .about: return Color(nsColor: .systemGray)
        }
    }
}

/// The small rounded-square icon System Settings uses in its sidebar.
struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(pane.tile.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: pane.symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let state: AppState
    @State private var pane: SettingsPane?

    init(settings: AppSettings, state: AppState, initialPane: SettingsPane = .general) {
        self.settings = settings
        self.state = state
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { p in
                Label { Text(p.title) } icon: { PaneIcon(pane: p) }
                    .tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralPane(settings: settings, state: state)
                case .look: AppearancePane(settings: settings)
                case .lanes: LanesPane(settings: settings, state: state)
                case .models: ModelsPane(settings: settings)
                case .worktrees: WorktreesPane(settings: settings, state: state)
                case .advice: AdvicePane(settings: settings)
                case .pricing: PricingPane(settings: settings, state: state)
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 700, minHeight: 480)
        .onDisappear { state.refresh() }
    }
}

// MARK: - Shared pieces

/// A path or URL field: monospaced value, a lock when an LLMBAR_* environment variable owns it.
struct PathRow: View {
    @ObservedObject var settings: AppSettings
    let label: String
    let key: AppSettings.Key

    var body: some View {
        let locked = settings.isEnvOverridden(key)
        LabeledContent {
            HStack(spacing: 6) {
                TextField(label, text: Binding(get: { settings.string(key) }, set: { settings.set(key, $0) }),
                          prompt: Text(key.fallback.isEmpty ? "none" : (key.fallback as NSString).abbreviatingWithTildeInPath))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .disabled(locked)
                if locked {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        .help("Set by \(key.env) in the environment")
                }
            }
        } label: {
            Text(label)
        }
        .help(locked ? "Set by \(key.env)" : "Default: \(key.fallback.isEmpty ? "none" : key.fallback)")
    }
}

private struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    let state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        } catch { message = "Launch at login: \(error.localizedDescription)" }
                    }))
                Picker("Open terminals in", selection: Binding(
                    get: { settings.string(AppSettings.terminal) },
                    set: { settings.set(AppSettings.terminal, $0) })) {
                    Text("Ghostty").tag("Ghostty")
                    Text("Terminal").tag("Terminal")
                }
            } footer: {
                if !message.isEmpty { Footnote(text: message) }
            }
            Section {
                LabeledContent("Keyboard") {
                    Text("⌘1 – ⌘3 switch tabs · ⌘R refresh · ⌘, settings").foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("Reset All Settings…", role: .destructive) { settings.resetAll(); state.refresh() }
                    Spacer()
                }
            } footer: {
                Footnote(text: "Environment variables (LLMBAR_*) always win over these settings and show as locked.")
            }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 14)], spacing: 14) {
                    ForEach(ThemeID.allCases) { id in
                        ThemeTile(id: id, selected: settings.theme == id) { settings.theme = id }
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Theme")
            } footer: {
                Footnote(text: "Themes change colour, type and controls only. Every theme shows the same tabs and views. Native and Slate follow the system's light or dark setting.")
            }
            Section("Density") {
                Toggle("Compact rows", isOn: Binding(get: { settings.compact }, set: { settings.compact = $0 }))
                Toggle("Tinted section headers", isOn: Binding(get: { settings.tinted }, set: { settings.tinted = $0 }))
            }
        }
    }
}

/// A miniature popover drawn with the theme's own tokens.
private struct ThemeTile: View {
    let id: ThemeID
    let selected: Bool
    let pick: () -> Void
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let t = Theme.of(id)
        Button(action: pick) {
            VStack(spacing: 6) {
                preview(t)
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
                Text(id.label).font(.callout.weight(selected ? .semibold : .regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(id.label) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func preview(_ t: Theme) -> some View {
        let scheme = t.scheme ?? systemScheme
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Capsule().fill(t.accent).frame(width: 30, height: 7)
                Capsule().fill(Color.primary.opacity(0.18)).frame(width: 22, height: 7)
                Capsule().fill(Color.primary.opacity(0.18)).frame(width: 22, height: 7)
            }
            VStack(alignment: .leading, spacing: 5) {
                line(t.live, 0.8)
                line(t.warn, 0.6)
                line(t.ready, 0.7)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t.band ?? .clear)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(t.ground ?? Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
        .fontDesign(t.fontDesign)
    }

    private func line(_ c: Color, _ w: CGFloat) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 5, height: 5)
            GeometryReader { g in Capsule().fill(Color.primary.opacity(0.35)).frame(width: g.size.width * w, height: 4) }
                .frame(height: 4)
        }
    }
}

// MARK: - Cloud lanes

private struct LanesPane: View {
    @ObservedObject var settings: AppSettings
    let state: AppState
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                PathRow(settings: settings, label: "Lane list (Claude config)", key: AppSettings.claudeConfig)
                PathRow(settings: settings, label: "Status cache", key: AppSettings.laneStatus)
                PathRow(settings: settings, label: "Probe script", key: AppSettings.laneProbe)
            } header: {
                Text("Sources")
            } footer: {
                Footnote(text: "Leave the probe script empty to use scripts/lane-status.zsh next to the config.")
            }
            Section("Show") {
                Toggle("Paid lanes", isOn: Binding(get: { settings.showPaid }, set: { settings.showPaid = $0 }))
                Toggle("Cheap OpenRouter lanes", isOn: Binding(get: { settings.showCheap }, set: { settings.showCheap = $0 }))
                Toggle("Free-tier lanes", isOn: Binding(get: { settings.showFree }, set: { settings.showFree = $0 }))
            }
            Section {
                Stepper("Probe daily at \(String(format: "%02d:00", settings.probeHour)) and at login",
                        value: Binding(get: { settings.probeHour }, set: { settings.probeHour = $0 }), in: 0...23)
                HStack {
                    Button(laneProbeAgentInstalled() ? "Reinstall Agent" : "Install Agent") {
                        message = installLaneProbeAgent(hour: settings.probeHour) ?? "Installed \(LANE_PROBE_LAUNCHD_LABEL)."
                        state.refresh()
                    }
                    if laneProbeAgentInstalled() {
                        Button("Remove Agent") { removeLaneProbeAgent(); message = "Removed."; state.refresh() }
                    }
                    Spacer()
                    Button("Probe Now") { state.refreshLanes(); message = "Probing…" }
                }
            } header: {
                Text("Daily probe")
            } footer: {
                Footnote(text: message.isEmpty ? "A launchd agent sends one 8-token request per lane and notifies on status changes." : message)
            }
        }
    }
}

// MARK: - Local models

private struct ModelsPane: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Form {
            Section("llama.cpp") {
                PathRow(settings: settings, label: "Models folder", key: AppSettings.lcpDir)
                PathRow(settings: settings, label: "llama-server", key: AppSettings.lcpServer)
                PathRow(settings: settings, label: "Pidfile", key: AppSettings.lcpPidfile)
            }
            Section("Ollama") {
                PathRow(settings: settings, label: "API host", key: AppSettings.ollamaHost)
            }
            Section("Hugging Face") {
                PathRow(settings: settings, label: "Cache folder", key: AppSettings.hfCache)
            }
        }
    }
}

// MARK: - Worktrees

private struct WorktreesPane: View {
    @ObservedObject var settings: AppSettings
    let state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Show the Worktrees tab", isOn: Binding(get: { settings.showWorktrees }, set: { settings.showWorktrees = $0 }))
                Toggle("Menu bar dot when a worktree is ready to retire", isOn: Binding(get: { settings.worktreeBadge }, set: { settings.worktreeBadge = $0 }))
            }
            Section {
                Picker("Refresh every", selection: Binding(
                    get: { settings.worktreeRefreshMinutes },
                    set: { settings.worktreeRefreshMinutes = $0; state.restartWorktreeTimer() })) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                LabeledContent("Sizes and audit") {
                    Text("every \(settings.worktreeRefreshMinutes * 6) minutes").foregroundStyle(.secondary)
                }
            } header: {
                Text("Refresh")
            } footer: {
                Footnote(text: "A listing walks every worktree with git and lsof, so it runs in the background. Opening the popover refreshes anything older than a minute.")
            }
            Section {
                PathRow(settings: settings, label: "wtr.py", key: AppSettings.wtrScript)
                PathRow(settings: settings, label: "Extra folders", key: AppSettings.wtrScanRoots)
            } header: {
                Text("Discovery")
            } footer: {
                Footnote(text: "Repos are found without configuration: from your agents' worktree folders, the repos next to them and the agents' ledger. Extra folders are optional, separated by colons.")
            }
            Section {
                LabeledContent("History") {
                    HStack(spacing: 8) {
                        Text("\(state.worktreeHistory.count) samples · 14 days").foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([WorktreeHistory.url]) }
                    }
                }
            } footer: {
                Footnote(text: "Read-only. The app never deletes a worktree; retiring stays with the skill's guarded script.")
            }
        }
    }
}

// MARK: - Advice (Jev)

private struct AdvicePane: View {
    @ObservedObject var settings: AppSettings
    @State private var found: String? = JevKey.existingService()
    @State private var entry = ""
    @State private var editing = false
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show Jev's suggestion on worktrees", isOn: Binding(get: { settings.showAdvice }, set: { settings.showAdvice = $0 }))
            } footer: {
                Footnote(text: "Jev suggests: deliver, ask the owner, archive or keep, and how likely a worktree is abandoned. It never decides and never touches a worktree. You do.")
            }
            Section {
                LabeledContent("API key") {
                    HStack(spacing: 8) {
                        if let found {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(nsColor: .systemGreen))
                            Text("In your keychain as \(found)").foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "key").foregroundStyle(.secondary)
                            Text("Not in your keychain").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(found == nil ? "Add Key…" : "Replace…") { editing = true; message = "" }
                    }
                }
                if editing {
                    LabeledContent("New key") {
                        HStack(spacing: 8) {
                            SecureField("Paste the key", text: $entry).textFieldStyle(.roundedBorder).labelsHidden()
                            Button("Save") {
                                switch JevKey.save(entry) {
                                case .success(let service):
                                    message = found == nil ? "Saved to your keychain as \(service)." : "Updated \(service). No second copy was made."
                                    found = service
                                    editing = false
                                case .failure(let e):
                                    message = e.description
                                }
                                entry = ""
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(entry.isEmpty)
                            Button("Cancel") { editing = false; entry = "" }
                        }
                    }
                }
            } header: {
                Text("TypeSafe key")
            } footer: {
                Footnote(text: message.isEmpty
                         ? "Looked up in the login keychain under JEV_API_KEY, then TYPESAFE_API_KEY. The key is never shown, and saving updates the existing entry instead of adding another."
                         : message)
            }
            Section {
                LabeledContent("What is sent") { Text("names, counts, ages, last commit subjects").foregroundStyle(.secondary) }
                LabeledContent("Never sent") { Text("code, diffs, file contents, the key itself").foregroundStyle(.secondary) }
                Link("TypeSafe docs", destination: URL(string: "https://docs.typesafe.ai")!)
            } header: {
                Text("Privacy")
            } footer: {
                Footnote(text: "Repos listed under advise_local_only in ~/.agents/ledger/config.json are never sent.")
            }
        }
        .onAppear { found = JevKey.existingService() }
    }
}

// MARK: - Pricing

private struct PricingPane: View {
    @ObservedObject var settings: AppSettings
    let state: AppState
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show model price under each lane", isOn: Binding(get: { settings.showPricing }, set: { settings.showPricing = $0 }))
                PathRow(settings: settings, label: "kosha registry", key: AppSettings.koshaRegistry)
            }
            Section {
                LabeledContent("Registry") {
                    HStack(spacing: 8) {
                        Text(message.isEmpty ? KoshaRegistry.shared.summary : message)
                            .foregroundStyle(.secondary).lineLimit(2)
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Update") {
                                busy = true
                                message = "Running kosha update and enrich…"
                                runKoshaUpdate { ok, msg in
                                    busy = false
                                    message = (ok ? "Updated. " : "Failed: ") + msg
                                    state.refresh()
                                }
                            }
                        }
                    }
                }
            } footer: {
                Footnote(text: "Update re-discovers providers and refreshes prices (kosha update, then kosha enrich).")
            }
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("LLM Bar").font(.title.weight(.semibold))
            Text(version).font(.callout).foregroundStyle(.secondary)
            Text("Every model you can reach, and every worktree your agents made, in the menu bar.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            Link("github.com/sriinnu/llm-bar", destination: URL(string: "https://github.com/sriinnu/llm-bar")!)
                .font(.callout)
            Text("MIT licence").font(.footnote).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - dev snapshot

/// `LLMBar --snapshot-settings out.png [pane=look] [dark]` renders the settings window content.
@MainActor
func snapshotSettings(output: String, options: [String]) -> Int32 {
    _ = NSApplication.shared
    let paneName = options.first { $0.hasPrefix("pane=") }.map { String($0.dropFirst(5)) } ?? "general"
    let dark = options.contains("dark")
    let view = SettingsSnapshotHost(pane: SettingsPane(rawValue: paneName) ?? .general)
        .frame(width: 760, height: 540)
        .environment(\.colorScheme, dark ? .dark : .light)
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 540)
    let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    w.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 3 }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return 3 }
    do { try png.write(to: URL(fileURLWithPath: output)) } catch { return 4 }
    return 0
}

private struct SettingsSnapshotHost: View {
    let pane: SettingsPane
    @State private var selection: SettingsPane? = nil
    var body: some View {
        SettingsViewSeeded(pane: pane)
    }
}

/// SettingsView with a chosen starting pane (snapshot only).
private struct SettingsViewSeeded: View {
    let pane: SettingsPane
    var body: some View {
        SettingsView(settings: AppSettings.shared, state: AppState(), initialPane: pane)
    }
}
