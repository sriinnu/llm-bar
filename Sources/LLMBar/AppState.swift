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

    // Worktrees: refreshed in the background on their own timer, never in the 1.5 s popover poll.
    @Published var worktreeRows: [WorktreeRow] = []
    @Published var worktreeError: String? = nil
    @Published var worktreeLoading = false
    @Published var worktreesLoadedAt: Date? = nil
    @Published var worktreeSizesAt: Date? = nil
    /// Last 14 days of samples (see History.swift); drives the Agents timeline and the trend.
    @Published var worktreeHistory: [HistorySample] = []
    private var worktreeTimer: Timer?
    private var worktreeTicks = 0
    /// Slow fields (--sizes, --audit) from the last deep pass, keyed by worktree path.
    private var deepFields: [String: WorktreeRow] = [:]
    var onWorktreesChanged: (() -> Void)?

    var worktreeRepos: [WorktreeRepo] { groupWorktrees(worktreeRows) }
    var worktreeReadyCount: Int { worktreeRows.filter(\.isReady).count }

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

    /// Cheap: re-read the lane status cache only (used by the menu-bar badge timer).
    func reloadLaneStatus() {
        if lanes.isEmpty { lanes = parseLanes() }
        if let doc = loadLaneStatus() {
            laneStatus = doc.lanes
            laneProbedAt = doc.probed_at
        }
    }

    /// Lanes (among the shown groups) whose status needs a human: auth, balance, down, error.
    var laneAttentionCount: Int {
        lanes.filter { AppSettings.shared.shows(group: $0.group) }
            .filter { ["auth", "balance", "down", "error"].contains(laneStatus[$0.name]?.status ?? "") }
            .count
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
            self.onLaneStatusChanged?()
        }
    }

    /// Set by the app delegate to update the menu-bar badge.
    var onLaneStatusChanged: (() -> Void)?

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

    // MARK: worktrees

    /// Starts the background timer; the first tick is a deep pass so sizes appear early.
    func restartWorktreeTimer() {
        worktreeTimer?.invalidate()
        guard AppSettings.shared.showWorktrees else { return }
        let minutes = max(1, AppSettings.shared.worktreeRefreshMinutes)
        worktreeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.worktreeTick() }
        }
        worktreeTimer?.tolerance = 30
        if worktreesLoadedAt == nil { refreshWorktrees(deep: true) }
    }

    private func worktreeTick() {
        worktreeTicks += 1
        refreshWorktrees(deep: worktreeTicks % 6 == 0)
    }

    /// Popover opened: refresh the fast listing if it is more than a minute old.
    func refreshWorktreesIfStale() {
        guard AppSettings.shared.showWorktrees else { return }
        if let at = worktreesLoadedAt, Date().timeIntervalSince(at) < 60 { return }
        refreshWorktrees(deep: false)
    }

    func refreshWorktrees(deep: Bool) {
        guard !worktreeLoading else { return }
        worktreeLoading = true
        loadWorktrees(deep: deep) { [weak self] result in
            guard let self else { return }
            self.worktreeLoading = false
            switch result {
            case .success(let rows):
                if deep {
                    self.deepFields = Dictionary(rows.map { ($0.worktree, $0) }, uniquingKeysWith: { a, _ in a })
                    self.worktreeSizesAt = Date()
                }
                self.worktreeRows = rows.map { self.withDeepFields($0) }
                WorktreeHistory.record(self.worktreeRows)
                self.worktreeHistory = WorktreeHistory.load(since: Date().addingTimeInterval(-Double(WorktreeHistory.keepDays) * 86400))
                self.worktreeError = nil
                self.worktreesLoadedAt = Date()
            case .failure(let e):
                self.worktreeError = e.description
            }
            self.onWorktreesChanged?()
        }
    }

    /// A fast row carries no size or verdict; reuse the last deep pass's values for the same path.
    private func withDeepFields(_ r: WorktreeRow) -> WorktreeRow {
        guard r.size_bytes == nil, let d = deepFields[r.worktree] else { return r }
        return WorktreeRow(name: r.name, worktree: r.worktree, repo: r.repo, repo_name: r.repo_name, branch: r.branch,
                           base: r.base, agents: r.agents, last_build: r.last_build, purpose: r.purpose, task: r.task,
                           status: r.status, verdict: r.verdict ?? d.verdict, main_checkout: r.main_checkout, origin: r.origin, advice: r.advice,
                           head_ts: r.head_ts, against: r.against, fetched_ts: r.fetched_ts, ahead: r.ahead, behind: r.behind,
                           dirty: r.dirty, live: r.live, idle_days: r.idle_days, agents_live: r.agents_live,
                           size_bytes: d.size_bytes, build_bytes: d.build_bytes)
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
