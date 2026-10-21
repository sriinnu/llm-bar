import SwiftUI
import Sparkle

// The popover is a native-style list, the way Control Center and the Wi-Fi menu read:
// small-caps section headers, hairline rows, no cards, no gradients. Section badges are
// small colourful glyphs (brand moments); every control is an SF Symbol (system moments).
func loadBadge(_ name: String) -> Image {
    let url = Bundle.main.url(forResource: name, withExtension: "svg")
        ?? Bundle.module.url(forResource: name, withExtension: "svg")
    if let url, let ns = NSImage(contentsOf: url) {
        return Image(nsImage: ns)
    }
    return Image(systemName: "square.grid.2x2")
}

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings = AppSettings.shared
    let updaterController: SPUStandardUpdaterController
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    cloudSection
                    lcpSection
                    ollamaSection
                    hfSection
                }
                .padding(.bottom, 6)
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .background(.regularMaterial)
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
                .font(.system(size: 13, weight: .semibold))
            Text(appVersion)
                .font(.system(size: 10))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Check for Updates…") { updaterController.checkForUpdates(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(!updaterController.updater.canCheckForUpdates)
            Spacer()
            Button("About") { AppWindows.showAbout() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            Button("Quit") { onQuit() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.laneProbeRunning {
                    ProgressView().controlSize(.mini)
                } else if state.laneProbeAvailable {
                    Button(action: { state.refreshLanes() }) {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Probe every lane now (one 8-token request each)")
                }
            }
            .padding(.horizontal, 14)
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
                    .padding(.horizontal, 14).padding(.vertical, 4)
                Rows(state.lcpModels) { model in
                    ModelRow(model: model,
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
                .padding(.horizontal, 14).padding(.vertical, 4)
            if !ollamaAppRunning() {
                EmptyRow(text: "Not running — start it to see models")
            } else if state.ollamaModels.isEmpty {
                EmptyRow(text: "No Ollama models")
            } else {
                Rows(state.ollamaModels) { model in
                    ModelRow(model: model, isActive: false, canStart: false, onStart: {},
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
                    ModelRow(model: model, isActive: false, canStart: false, onStart: {},
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
private let sectionTints: [String: Color] = [
    "badge-cloud": Color(red: 0.18, green: 0.71, blue: 1.00),   // #2FB4FF
    "badge-lcp": Color(red: 0.49, green: 0.42, blue: 1.00),     // #7C6CFF
    "badge-ollama": Color(red: 0.13, green: 0.83, blue: 0.93),  // #22D3EE
    "badge-hf": Color(red: 0.98, green: 0.75, blue: 0.14),      // #FBBF24
]

/// A section: small-caps header with a tiny badge and a trailing count, then its rows.
private struct SectionBlock<Content: View>: View {
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
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(headerStyle)
                Spacer()
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(headerStyle)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, settings.compact ? 9 : 12)
            .padding(.bottom, settings.compact ? 2 : 4)
            content
        }
    }
}

/// Rows separated by hairlines, inset like a macOS menu.
private struct Rows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let row: (Item) -> Row
    @ObservedObject private var settings = AppSettings.shared
    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) { self.items = items; self.row = row }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 {
                    Divider().padding(.leading, 14).opacity(0.5)
                }
                row(item)
                    .padding(.horizontal, 14)
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
                    Text(lane.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    if showDescription {
                        Text(lane.description)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if showPricing, let s = status, !s.model.isEmpty {
                    HStack(spacing: 4) {
                        Text(s.model)
                            .font(.system(size: 9.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let p = KoshaRegistry.shared.price(model: s.model, provider: s.kosha_provider) {
                            Text("· " + formatPrice(p))
                                .font(.system(size: 9.5))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            if let s = status, s.status == "ok", s.ms > 0 {
                Text("\(s.ms) ms")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else if let s = status, s.status != "ok" {
                Text(s.status)
                    .font(.system(size: 10))
                    .foregroundStyle(dotColor)
                    .padding(.top, 2)
            }
            Button(action: onLaunch) {
                Image(systemName: "terminal").font(.system(size: 10))
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

private struct ModelRow: View {
    let model: ModelEntry
    let isActive: Bool
    let canStart: Bool
    let onStart: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(model.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if model.sizeBytes > 0 {
                Text(byteFormatter.string(fromByteCount: model.sizeBytes))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if model.isCloud {
                Image(systemName: "cloud").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if canStart {
                Button(action: onStart) {
                    Image(systemName: isActive ? "waveform" : "play.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(isActive)
                .help(isActive ? "Running" : "Start with this model")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { onReveal() }
    }
}

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
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
            Text(statusText).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer()
            if case .running = state {
                Button(action: onStop) { Image(systemName: "stop.fill").font(.system(size: 10)) }
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
            Text(label + " " + statusText).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer()
            switch state {
            case .running:
                Button(action: onStop) { Image(systemName: "stop.fill").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help("Quit Ollama")
            default:
                Button(action: onStart) { Image(systemName: "play.fill").font(.system(size: 10)) }
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

private struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}
