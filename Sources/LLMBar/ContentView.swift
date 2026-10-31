import SwiftUI
import Sparkle

// The popover is a native-style list, the way Control Center and the Wi-Fi menu read:
// small-caps section headers, hairline rows, no cards, no gradients. Section badges are
// small colourful glyphs (brand moments); every control is an SF Symbol (system moments).
func loadBadge(_ name: String) -> Image {
    let url = Bundle.main.url(forResource: name, withExtension: "svg")
        ?? Bundle.module.url(forResource: name, withExtension: "svg")
        ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources")   // `swift run` nests .copy("Resources")
    if let url, let ns = NSImage(contentsOf: url) {
        ns.isTemplate = (name == "icon")   // the app mark is a template: it takes the text colour
        return Image(nsImage: ns)
    }
    return Image(systemName: "square.grid.2x2")
}

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings = AppSettings.shared
    let updaterController: SPUStandardUpdaterController
    var onQuit: () -> Void

    enum Tab: String, CaseIterable { case lanes, models, worktrees }

    private var tab: Tab {
        let t = Tab(rawValue: settings.lastTab) ?? .worktrees
        return (t == .worktrees && !settings.showWorktrees) ? .lanes : t
    }
    private var tabs: [Tab] { settings.showWorktrees ? Tab.allCases : [.lanes, .models] }

    var body: some View {
        let theme = Theme.of(settings.theme)
        VStack(spacing: 0) {
            header
            TabBar(tabs: tabs, current: tab, badges: badges, select: { settings.lastTab = $0.rawValue })
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .lanes: cloudSection
                    case .models:
                        lcpSection
                        ollamaSection
                        hfSection
                    case .worktrees: WorktreesTab(state: state)
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(minHeight: 380, maxHeight: 560)
            Hairline()
            footer
        }
        .frame(width: 380)
        .themed(theme)
    }

    private var badges: [Tab: (String, Bool)] {
        var b: [Tab: (String, Bool)] = [:]
        let lanes = state.laneAttentionCount
        if lanes > 0 { b[.lanes] = ("\(lanes)", true) }
        let ready = state.worktreeReadyCount
        let total = state.worktreeRows.filter { !$0.isMain && !$0.isStale }.count
        if total > 0 { b[.worktrees] = (ready > 0 ? "\(total) · \(ready)" : "\(total)", false) }
        return b
    }

    // MARK: header / footer

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    private var header: some View {
        HStack(spacing: 8) {
            loadBadge("icon")
                .resizable()
                .frame(width: 18, height: 18)
            Text("LLM Bar")
                .font(.headline)
            Text(appVersion)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { state.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh (⌘R)")
            Button(action: { AppWindows.showSettings(state: state) }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // Status bar: who made it (and how to support that) on the left, app actions as icons on the right.
    private var footer: some View {
        HStack(spacing: 2) {
            Link(destination: URL(string: "https://github.com/sriinnu")!) {
                HStack(spacing: 4) {
                    Text("Sriinnu").font(.subheadline.weight(.medium))
                    Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("github.com/sriinnu")
            Link(destination: URL(string: "https://github.com/sponsors/sriinnu")!) {
                Image(systemName: "heart.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .systemPink))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sponsor LLM Bar on GitHub")
            .accessibilityLabel("Sponsor")
            Spacer()
            FooterIcon(symbol: "arrow.triangle.2.circlepath", help: "Check for Updates") {
                updaterController.checkForUpdates(nil)
            }
            .disabled(!updaterController.updater.canCheckForUpdates)
            FooterIcon(symbol: "info.circle", help: "About LLM Bar") { AppWindows.showAbout() }
            FooterIcon(symbol: "power", help: "Quit LLM Bar (⌘Q)") { onQuit() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: sections

    private var shownLanes: [LaneEntry] {
        state.lanes.filter { settings.shows(group: $0.group) }
    }

    private var cloudSection: some View {
        let lanes = shownLanes
        let ok = lanes.filter { state.laneStatus[$0.name]?.status == "ok" }.count
        let bad = lanes.filter { ["auth", "balance", "down", "error"].contains(state.laneStatus[$0.name]?.status ?? "") }.count
        var trailing = lanes.isEmpty ? "" : "\(ok)/\(lanes.count) up"
        if bad > 0 { trailing += " · \(bad) need attention" }
        return SectionBlock(badge: "badge-cloud", title: "Cloud lanes", trailing: trailing) {
            HStack(spacing: 6) {
                Text(state.laneProbedAt.map { "probed \(relativeAge($0))" } ?? "not probed yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if state.laneProbeRunning {
                    ProgressView().controlSize(.mini)
                } else if state.laneProbeAvailable {
                    Button(action: { state.refreshLanes() }) {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .help("Probe every lane now (one 8-token request each)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            if lanes.isEmpty {
                EmptyRow(text: "No lanes found — expected an lcp-help block in \(CLAUDE_CONFIG_PATH)")
            } else {
                Rows(lanes) { lane in
                    LaneRow(lane: lane, status: state.laneStatus[lane.name],
                            showPricing: settings.showPricing && !settings.compact,
                            showDescription: !settings.compact,
                            onLaunch: { launchLane(lane.name) })
                }
            }
        }
    }

    private var lcpSection: some View {
        let empty = state.lcpModels.isEmpty && !isRunningOrStarting(state.lcpState)
        return SectionBlock(badge: "badge-lcp", title: "Local · llama.cpp", trailing: subtitle(for: state.lcpModels)) {
            if empty {
                EmptyRow(text: "No GGUF models in \((LCP_MODELS_DIR as NSString).abbreviatingWithTildeInPath)")
            } else {
                ServerControlRow(state: state.lcpState, runningLabel: "llama-server · port \(LCP_PORT)", onStop: { state.stopLcp() })
                    .padding(.horizontal, 16).padding(.vertical, 4)
                Rows(state.lcpModels) { model in
                    ModelRow(model: model, source: .lcp,
                             isActive: state.lcpActiveModelPath == model.path && isRunningOrStarting(state.lcpState),
                             canStart: model.path != nil,
                             onStart: { state.startLcp(model) },
                             onReveal: { revealInFinder(model.path) })
                }
            }
        }
    }

    private var ollamaSection: some View {
        SectionBlock(badge: "badge-ollama", title: "Ollama", trailing: subtitle(for: state.ollamaModels)) {
            AppControlRow(state: state.ollamaAppState, label: "Ollama.app",
                          onStart: { state.startOllama() }, onStop: { state.stopOllama() })
                .padding(.horizontal, 16).padding(.vertical, 4)
            if !ollamaAppRunning() {
                EmptyRow(text: "Not running — start it to see models")
            } else if state.ollamaModels.isEmpty {
                EmptyRow(text: "No Ollama models")
            } else {
                Rows(state.ollamaModels) { model in
                    ModelRow(model: model, source: .ollama, isActive: false, canStart: false, onStart: {},
                             onReveal: { copyToClipboard(model.name) })
                }
            }
        }
    }

    private var hfSection: some View {
        SectionBlock(badge: "badge-hf", title: "Hugging Face cache", trailing: subtitle(for: state.hfModels)) {
            if state.hfModels.isEmpty {
                EmptyRow(text: "Cache empty")
            } else {
                Rows(state.hfModels) { model in
                    ModelRow(model: model, source: .hf, isActive: false, canStart: false, onStart: {},
                             onReveal: { revealInFinder(model.path) })
                }
            }
        }
    }

    // MARK: helpers

    private func subtitle(for models: [ModelEntry]) -> String {
        guard !models.isEmpty else { return "" }
        let total = models.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let countStr = "\(models.count)"
        return total > 0 ? "\(countStr) · \(byteFormatter.string(fromByteCount: total))" : countStr
    }

    private func isRunningOrStarting(_ s: ServerState) -> Bool {
        switch s {
        case .running, .starting: return true
        default: return false
        }
    }

    private func revealInFinder(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Section + rows

/// Badge gradient start colours, for the tinted look.
let sectionTints: [String: Color] = [
    "badge-cloud": Color(red: 0.18, green: 0.71, blue: 1.00),   // #2FB4FF
    "badge-lcp": Color(red: 0.49, green: 0.42, blue: 1.00),     // #7C6CFF
    "badge-ollama": Color(red: 0.13, green: 0.83, blue: 0.93),  // #22D3EE
    "badge-hf": Color(red: 0.98, green: 0.75, blue: 0.14),      // #FBBF24
]

/// A section: small-caps header with a tiny badge and a trailing count, then its rows.
struct SectionBlock<Content: View>: View {
    let badge: String
    let title: String
    let trailing: String
    @ViewBuilder let content: Content
    @ObservedObject private var settings = AppSettings.shared

    private var headerStyle: AnyShapeStyle {
        if settings.tinted, let c = sectionTints[badge] { return AnyShapeStyle(c) }
        return AnyShapeStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                loadBadge(badge)
                    .resizable()
                    .frame(width: 13, height: 13)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                Text(title.uppercased())
                    .font(.footnote.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(headerStyle)
                Spacer()
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(.footnote)
                        .foregroundStyle(headerStyle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, settings.compact ? 9 : 12)
            .padding(.bottom, settings.compact ? 2 : 4)
            content
        }
    }
}

/// Rows separated by hairlines, inset like a macOS menu.
struct Rows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let row: (Item) -> Row
    @ObservedObject private var settings = AppSettings.shared
    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) { self.items = items; self.row = row }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 {
                    Divider().padding(.leading, 16).opacity(0.5)
                }
                row(item)
                    .padding(.horizontal, 16)
                    .padding(.vertical, settings.compact ? 3 : 5)
            }
        }
    }
}

private struct LaneRow: View {
    let lane: LaneEntry
    let status: LaneStatus?
    let showPricing: Bool
    let showDescription: Bool
    let onLaunch: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: dotColor)
                .padding(.top, 4)
                .help(statusHelp)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    TruncatedName(text: lane.name, font: .body.weight(.medium), mode: .tail)
                    if showDescription {
                        Text(lane.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if showPricing, let s = status, !s.model.isEmpty {
                    HStack(spacing: 4) {
                        Text(s.model)
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let p = KoshaRegistry.shared.price(model: s.model, provider: s.kosha_provider) {
                            Text("· " + formatPrice(p))
                                .font(.footnote)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            if let s = status, s.status == "ok", s.ms > 0 {
                Text("\(s.ms) ms")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else if let s = status, s.status != "ok" {
                Text(s.status)
                    .font(.footnote)
                    .foregroundStyle(dotColor)
                    .padding(.top, 2)
            }
            Button(action: onLaunch) {
                Image(systemName: "terminal").font(.footnote)
            }
            .buttonStyle(.borderless)
            .help("Open `\(lane.name)` in \(TERMINAL_APP)")
        }
    }

    private var dotColor: Color {
        switch status?.status {
        case "ok": return .green
        case "ratelimit": return .yellow
        case "auth", "balance", "down", "error": return .red
        case "nokey": return .orange
        default: return .secondary.opacity(0.4)
        }
    }

    private var statusHelp: String {
        guard let s = status else { return "not probed" }
        var t = "\(s.status) · HTTP \(s.http) · \(s.model)"
        if let d = s.detail, !d.isEmpty { t += "\n\(d)" }
        if let w = s.shared_with { t += "\n(shares endpoint + key with \(w))" }
        return t
    }
}

/// Where a model lives decides how it opens: llama.cpp GGUFs through `lcp`, Ollama models through
/// Ollama's own Claude Code integration, Hugging Face snapshots just reveal.
enum ModelSource { case lcp, ollama, hf }

private struct ModelRow: View {
    let model: ModelEntry
    let source: ModelSource
    let isActive: Bool
    let canStart: Bool
    let onStart: () -> Void
    let onReveal: () -> Void

    /// `lcp` takes a name hint: the GGUF file name without extension.
    private var lcpHint: String { ((model.path ?? model.name) as NSString).lastPathComponent.replacingOccurrences(of: ".gguf", with: "") }

    var body: some View {
        HStack(spacing: 8) {
            TruncatedName(text: model.name, font: .body)
            Spacer(minLength: 6)
            if model.sizeBytes > 0 {
                Text(byteFormatter.string(fromByteCount: model.sizeBytes))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if model.isCloud {
                Image(systemName: "cloud").font(.footnote).foregroundStyle(.secondary)
            }
            if source != .hf && !model.isCloud {
                Button(action: openInClaudeCode) {
                    Image(systemName: "terminal").font(.footnote)
                }
                .buttonStyle(.borderless)
                .help("Open in Claude Code")
            }
            if canStart {
                Button(action: onStart) {
                    Image(systemName: isActive ? "waveform" : "play.fill").font(.footnote)
                }
                .buttonStyle(.borderless)
                .disabled(isActive)
                .help(isActive ? "Running" : "Start llama-server with this model")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { onReveal() }
        .contextMenu {
            if source != .hf && !model.isCloud {
                Button("Open in Claude Code") { openInClaudeCode() }
            }
            if source == .ollama {
                Button("Chat in \(TERMINAL_APP)") { runInTerminal("ollama run \(shellQuote(model.name))") }
            }
            Divider()
            if let path = model.path {
                Button("Copy Path") { copy(path) }
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            }
            Button("Copy Name") { copy(model.name) }
        }
    }

    private func openInClaudeCode() {
        switch source {
        case .lcp: runInTerminal("lcp \(shellQuote(lcpHint))")
        case .ollama: runInTerminal("ollama launch claude --model \(shellQuote(model.name))")
        case .hf: break
        }
    }
}

struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
    }
}

private struct ServerControlRow: View {
    let state: ServerState
    let runningLabel: String
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color)
            Text(statusText).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if case .running = state {
                Button(action: onStop) { Image(systemName: "stop.fill").font(.footnote) }
                    .buttonStyle(.borderless)
                    .help("Stop server")
            }
        }
    }
    private var statusText: String {
        switch state {
        case .stopped: return "stopped"
        case .starting: return "starting…"
        case .running: return runningLabel
        case .error(let msg): return "error: \(msg)"
        }
    }
    private var color: Color { serverColor(state) }
}

private struct AppControlRow: View {
    let state: ServerState
    let label: String
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: serverColor(state))
            Text(label + " " + statusText).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            switch state {
            case .running:
                Button(action: onStop) { Image(systemName: "stop.fill").font(.footnote) }
                    .buttonStyle(.borderless).help("Quit Ollama")
            default:
                Button(action: onStart) { Image(systemName: "play.fill").font(.footnote) }
                    .buttonStyle(.borderless).help("Launch Ollama")
            }
        }
    }
    private var statusText: String {
        switch state {
        case .stopped: return "stopped"
        case .starting: return "starting…"
        case .running: return "running"
        case .error: return "error"
        }
    }
}

private func serverColor(_ s: ServerState) -> Color {
    switch s {
    case .running: return .green
    case .starting: return .yellow
    case .error: return .red
    case .stopped: return .secondary.opacity(0.4)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

// MARK: - Tab bar (one structure, three looks)

struct TabBar: View {
    let tabs: [ContentView.Tab]
    let current: ContentView.Tab
    let badges: [ContentView.Tab: (String, Bool)]   // text, isAlert
    let select: (ContentView.Tab) -> Void
    @Environment(\.theme) private var theme

    private func title(_ t: ContentView.Tab) -> String {
        switch t {
        case .lanes: return "Lanes"
        case .models: return "Models"
        case .worktrees: return "Worktrees"
        }
    }

    var body: some View {
        Group {
            switch theme.id {
            case .native, .slate, .midnight:
                Picker("", selection: Binding(get: { current }, set: { select($0) })) {
                    ForEach(tabs, id: \.self) { t in
                        Text(badges[t].map { "\(title(t)) \($0.0)" } ?? title(t)).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .background {
                    // ⌘1–⌘3 for the segmented control too
                    HStack {
                        ForEach(Array(tabs.enumerated()), id: \.element) { i, t in
                            Button("") { select(t) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                        }
                    }.opacity(0).allowsHitTesting(false)
                }
            case .terminal:
                HStack(spacing: 16) {
                    ForEach(Array(tabs.enumerated()), id: \.element) { i, t in
                        Button(action: { select(t) }) {
                            HStack(spacing: 4) {
                                Text("\(i + 1)").foregroundStyle(t == current ? theme.accent : Color.secondary.opacity(0.6))
                                Text(title(t).lowercased()).fontWeight(t == current ? .bold : .regular)
                                    .foregroundStyle(t == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                badge(t)
                            }
                            .font(.body)
                            .padding(.vertical, 4)
                            .overlay(alignment: .bottom) { if t == current { Rectangle().fill(theme.accent).frame(height: 2).offset(y: 4) } }
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            case .editorial:
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    ForEach(Array(tabs.enumerated()), id: \.element) { i, t in
                        Button(action: { select(t) }) {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(title(t))
                                    .font(.system(size: 15, weight: t == current ? .heavy : .medium))
                                    .foregroundStyle(t == current ? Color.primary : Color.secondary)
                                    .underline(t == current, color: .primary)
                                if let (text, alert) = badges[t], alert {
                                    Text(text).font(.caption2.weight(.bold)).foregroundStyle(theme.accent).baselineOffset(6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func badge(_ t: ContentView.Tab) -> some View {
        if let (text, alert) = badges[t] {
            Text(text)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(alert ? theme.danger : Color.secondary)
        }
    }
}


/// A borderless icon button for the status bar: 26×22 hit area, tooltip, accessibility label.
struct FooterIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
