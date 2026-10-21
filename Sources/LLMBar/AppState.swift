import Foundation
import Combine

enum ServerState {
    case stopped
    case starting
    case running
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var lcpModels: [ModelEntry] = []
    @Published var lcpState: ServerState = .stopped
    @Published var lcpActiveModelPath: String? = nil

    @Published var ollamaModels: [ModelEntry] = []
    @Published var ollamaAppState: ServerState = .stopped

    @Published var hfModels: [ModelEntry] = []

    @Published var lanes: [LaneEntry] = []
    @Published var laneStatus: [String: LaneStatus] = [:]
    @Published var laneProbedAt: String? = nil
    @Published var laneProbeRunning = false
    @Published var laneProbeAvailable = FileManager.default.isReadableFile(atPath: LANE_PROBE_PATH)

    private var pollTimer: Timer?

    func refresh() {
        let lcp = fetchLcpModels()
        let running = lcpServerRunning()
        self.lcpModels = lcp
        if running {
            self.lcpState = .running
        } else if case .starting = self.lcpState {
            // leave "starting" alone — a background health check flips it
        } else {
            self.lcpState = .stopped
        }

        self.ollamaModels = LLMBar_ollamaModelsIfRunning()
        self.ollamaAppState = ollamaAppRunning() ? .running : .stopped

        self.hfModels = fetchHfCacheModels()

        self.lanes = parseLanes()
        if let doc = loadLaneStatus() {
            self.laneStatus = doc.lanes
            self.laneProbedAt = doc.probed_at
        }
    }

    /// Re-probes every lane (5–10 s, network) and reloads the cache.
    func refreshLanes() {
        guard !laneProbeRunning else { return }
        laneProbeRunning = true
        runLaneProbe { [weak self] _ in
            guard let self else { return }
            self.laneProbeRunning = false
            if let doc = loadLaneStatus() {
                self.laneStatus = doc.lanes
                self.laneProbedAt = doc.probed_at
            }
        }
    }

    /// Called once when the popover opens; polls a few times while a server
    /// is mid-startup so the UI flips from "starting…" to "running" without
    /// the user having to close and reopen the popover.
    func startPolling() {
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func startLcp(_ model: ModelEntry) {
        guard let path = model.path else { return }
        lcpState = .starting
        lcpActiveModelPath = path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = startLcpServer(modelPath: path)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .started, .alreadyRunning:
                    self.lcpState = .running
                case .binaryMissing:
                    self.lcpState = .error("llama-server not found at \(LCP_SERVER_PATH)")
                case .insufficientMemory(let availableGB, let neededGB):
                    self.lcpState = .error(String(format: "needs ~%.1fGB free, only %.1fGB available", neededGB, availableGB))
                    self.lcpActiveModelPath = nil
                case .failed(let msg):
                    self.lcpState = .error(msg)
                }
            }
        }
    }

    func stopLcp() {
        stopLcpServer()
        lcpState = .stopped
        lcpActiveModelPath = nil
    }

    func startOllama() {
        ollamaAppState = .starting
        startOllamaApp()
    }

    func stopOllama() {
        stopOllamaApp()
        ollamaAppState = .stopped
    }
}

// Ollama's /api/tags 1.5s-timeout probe is a bit much to run every 1.5s poll
// tick when the app isn't even running — skip the network round trip if the
// app process itself isn't up.
private func LLMBar_ollamaModelsIfRunning() -> [ModelEntry] {
    guard ollamaAppRunning() else { return [] }
    return fetchOllamaModels()
}
