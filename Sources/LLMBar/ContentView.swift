import SwiftUI
import Sparkle

// Badge icons are small colorful SVG glyphs (Settings-app style — a
// distinct gradient badge per section) loaded via Bundle.main/Bundle.module,
// same trick as the menu-bar icon. SF Symbols are used for every interactive
// control (play/stop/refresh) — that's the HIG-correct split: custom art for
// brand/identity moments, system symbols for actions, so buttons still look
// and behave like every other macOS control.
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

            ScrollView {
                VStack(spacing: 14) {
                    SectionCard(
                        badge: loadBadge("badge-lcp"),
                        title: "Local (lcp)",
                        subtitle: subtitle(for: state.lcpModels)
                    ) {
                        ServerControlRow(
                            state: state.lcpState,
                            runningLabel: "llama-server · port \(LCP_PORT)",
                            onStop: { state.stopLcp() }
                        )
                        if state.lcpModels.isEmpty {
                            EmptyRow(text: "No GGUF models downloaded — try \"hf\" or \"lcp --pull\" in Terminal")
                        } else {
                            ForEach(state.lcpModels) { model in
                                ModelRow(
                                    model: model,
                                    isActive: state.lcpActiveModelPath == model.path && isRunningOrStarting(state.lcpState),
                                    canStart: model.path != nil,
                                    onStart: { state.startLcp(model) },
                                    onReveal: { revealInFinder(model.path) }
                                )
                            }
                        }
                    }

                    SectionCard(
                        badge: loadBadge("badge-ollama"),
                        title: "Ollama",
                        subtitle: subtitle(for: state.ollamaModels)
                    ) {
                        HStack {
                            AppControlRow(
                                state: state.ollamaAppState,
                                label: "Ollama.app",
                                onStart: { state.startOllama() },
                                onStop: { state.stopOllama() }
                            )
                        }
                        if !ollamaAppRunning() {
                            EmptyRow(text: "Ollama isn't running — start it to see models")
                        } else if state.ollamaModels.isEmpty {
                            EmptyRow(text: "No Ollama models")
                        } else {
                            ForEach(state.ollamaModels) { model in
                                ModelRow(
                                    model: model,
                                    isActive: false,
                                    canStart: false,
                                    onStart: {},
                                    onReveal: { copyToClipboard(model.name) }
                                )
                            }
                        }
                    }

                    SectionCard(
                        badge: loadBadge("badge-cloud"),
                        title: "Cloud lanes",
                        subtitle: laneSubtitle
                    ) {
                        HStack(spacing: 6) {
                            Text(state.laneProbedAt.map { "probed \(relativeAge($0))" } ?? "not probed yet")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if state.laneProbeRunning {
                                ProgressView().controlSize(.mini)
                            } else if state.laneProbeAvailable {
                                Button(action: { state.refreshLanes() }) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.borderless)
                                .help("Probe every lane now (one 8-token request each)")
                            }
                        }
                        if state.lanes.isEmpty {
                            EmptyRow(text: "No lanes found — expected an lcp-help block in \(CLAUDE_CONFIG_PATH)")
                        } else {
                            ForEach(state.lanes.filter { settings.shows(group: $0.group) }) { lane in
                                LaneRow(
                                    lane: lane,
                                    status: state.laneStatus[lane.name],
                                    showPricing: settings.showPricing,
                                    onLaunch: { launchLane(lane.name) }
                                )
                            }
                        }
                    }

                    SectionCard(
                        badge: loadBadge("badge-hf"),
                        title: "Hugging Face cache",
                        subtitle: subtitle(for: state.hfModels)
                    ) {
                        if state.hfModels.isEmpty {
                            EmptyRow(text: "Cache empty — models downloaded straight into project folders")
                        } else {
                            ForEach(state.hfModels) { model in
                                ModelRow(
                                    model: model,
                                    isActive: false,
                                    canStart: false,
                                    onStart: {},
                                    onReveal: { revealInFinder(model.path) }
                                )
                            }
                        }
                    }
                }
                .padding(14)
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    private var header: some View {
        HStack(spacing: 8) {
            loadBadge("icon")
                .resizable()
                .frame(width: 20, height: 20)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("LLM Bar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.49, green: 0.42, blue: 1.0), Color(red: 0.18, green: 0.71, blue: 1.0)], startPoint: .leading, endPoint: .trailing))
                Text(appVersion)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
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
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Check for Updates…") {
                updaterController.checkForUpdates(nil)
            }
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

    private func subtitle(for models: [ModelEntry]) -> String {
        guard !models.isEmpty else { return "" }
        let total = models.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let countStr = "\(models.count) model\(models.count == 1 ? "" : "s")"
        return total > 0 ? "\(countStr) · \(byteFormatter.string(fromByteCount: total))" : countStr
    }

    private var laneSubtitle: String {
        let lanes = state.lanes.filter { settings.shows(group: $0.group) }
        guard !lanes.isEmpty else { return "" }
        let ok = lanes.filter { state.laneStatus[$0.name]?.status == "ok" }.count
        let bad = lanes.filter { ["auth", "balance", "down", "error"].contains(state.laneStatus[$0.name]?.status ?? "") }.count
        var parts = ["\(lanes.count) lanes"]
        if ok > 0 { parts.append("\(ok) up") }
        if bad > 0 { parts.append("\(bad) need attention") }
        return parts.joined(separator: " · ")
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

// MARK: - Section card

private struct SectionCard<Content: View>: View {
    let badge: Image
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                badge
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            content
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 3)
        )
    }
}

// MARK: - Rows

private struct ModelRow: View {
    let model: ModelEntry
    let isActive: Bool
    let canStart: Bool
    let onStart: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(model.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if model.sizeBytes > 0 {
                Text(byteFormatter.string(fromByteCount: model.sizeBytes))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if model.isCloud {
                Image(systemName: "cloud")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if canStart {
                Button(action: onStart) {
                    Image(systemName: isActive ? "waveform" : "play.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(isActive)
                .help(isActive ? "Running" : "Start with this model")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { onReveal() }
        .padding(.vertical, 2)
    }
}

private struct LaneRow: View {
    let lane: LaneEntry
    let status: LaneStatus?
    let showPricing: Bool
    let onLaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            mainLine
            if showPricing, let s = status, !s.model.isEmpty {
                HStack(spacing: 4) {
                    Text(s.model)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let p = KoshaRegistry.shared.price(model: s.model, provider: s.kosha_provider) {
                        Text("· " + formatPrice(p))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 13)
            }
        }
        .padding(.vertical, 2)
    }

    private var mainLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .help(statusHelp)
            Text(lane.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Text(lane.description)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let s = status, s.status == "ok", s.ms > 0 {
                Text("\(s.ms) ms")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let s = status, s.status != "ok" {
                Text(s.status)
                    .font(.system(size: 10))
                    .foregroundStyle(dotColor)
            }
            Button(action: onLaunch) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
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

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ServerControlRow: View {
    let state: ServerState
    let runningLabel: String
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: state)
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            if case .running = state {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                }
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
}

private struct AppControlRow: View {
    let state: ServerState
    let label: String
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: state)
            Text(label + " " + statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            switch state {
            case .running:
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Quit Ollama")
            default:
                Button(action: onStart) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Launch Ollama")
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

private struct StatusDot: View {
    let state: ServerState
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
    private var color: Color {
        switch state {
        case .running: return .green
        case .starting: return .yellow
        case .error: return .red
        case .stopped: return .secondary.opacity(0.4)
        }
    }
}
