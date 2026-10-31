import AppKit
import Foundation

// Worktrees = every git worktree any coding agent (Claude Code, Codex, Gemini, Cursor,
// OpenCode, Qwen, Copilot, pi, ribhu, …) created, read from the worktree-lifecycle skill's
// `wtr.py ls --json`. The app never runs git itself: one source of truth, shared with the
// agents. It is read-only — reveal, open a terminal, copy commands. Retiring stays with
// the skill's guarded script.

var WTR_SCRIPT: String { AppSettings.shared.string(AppSettings.wtrScript) }
var WTR_SCAN_ROOTS: [String] {
    AppSettings.shared.string(AppSettings.wtrScanRoots)
        .split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "\n" })
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { $0.hasPrefix("~") ? NSHomeDirectory() + $0.dropFirst() : $0 }
}

struct WorktreeProc: Decodable, Hashable {
    let pid: Int
    let kind: String
    let cmd: String?
    /// The nearest coding-agent ancestor (agents work through child shells, so the agent's own cwd is elsewhere).
    let agent: AgentRef?
}

struct AgentRef: Decodable, Hashable {
    let pid: Int
    let kind: String
}

struct WorktreeDirty: Decodable, Hashable {
    let tracked: Int
    let untracked: Int
}

struct WorktreeBase: Decodable, Hashable {
    let ref: String?
    let sha: String?
    let how: String?
}

struct WorktreeBuild: Decodable, Hashable {
    let status: String?
    let version: String?
    let build: String?
    let ts: String?

    /// "1.2.3 b42" / "b42" / "1.2.3", whatever the agent recorded.
    var label: String? {
        let parts = [version, build.map { $0.hasPrefix("b") ? $0 : "b" + $0 }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// One row of `wtr.py ls --json`. Every field the skill may omit is optional, so an older
/// or newer skill never breaks decoding.
struct WorktreeRow: Decodable, Identifiable, Hashable {
    var id: String { worktree }
    let name: String
    let worktree: String
    let repo: String
    let repo_name: String?
    let branch: String?
    let base: WorktreeBase?
    let agents: [String: AgentJoin]?
    let last_build: WorktreeBuild?
    let purpose: String?
    let task: String?
    let status: String?            // mapped | born | unmapped | stale | gone | retired | main
    let verdict: String?           // with --audit: CANDIDATE | KEEP | …
    let main_checkout: Bool?
    let origin: Origin?            // which coding agent created it (wtr.py), when known
    let advice: Advice?            // Jev's latest suggestion (advisory only), when one was recorded
    // --stats
    let head_ts: String?
    let against: String?
    let fetched_ts: String?
    let ahead: Int?
    let behind: Int?
    let dirty: WorktreeDirty?
    let live: [WorktreeProc]?
    let idle_days: Double?
    let agents_live: [AgentRef]?    // --stats: distinct agent ancestors of processes here
    // --sizes
    let size_bytes: Int64?
    let build_bytes: Int64?

    /// Jev (TypeSafe) advice recorded by wtr_advise.py. A suggestion for the human, never an action.
    struct Advice: Decodable, Hashable {
        struct Abandoned: Decodable, Hashable { let normalized: Double?; let confidence: Double? }
        struct Purpose: Decodable, Hashable { let text: String?; let confidence: Double? }
        let decision: String?
        let confidence: Double?
        let options: [String: Double]?
        let abandoned: Abandoned?
        let purpose: Purpose?
        let model: String?
        let ts: String?

        var decisionLabel: String {
            switch decision {
            case "deliver": return "Deliver (open a PR)"
            case "ask_owner": return "Ask the owner"
            case "archive": return "Archive with a recovery ref"
            case "keep_working": return "Keep working"
            default: return decision ?? "—"
            }
        }
        var shortLabel: String {
            switch decision {
            case "deliver": return "deliver"
            case "ask_owner": return "ask owner"
            case "archive": return "archive"
            case "keep_working": return "keep"
            default: return decision ?? ""
            }
        }
    }

    struct Origin: Decodable, Hashable {
        let agent: String?
        let how: String?
    }

    /// The agent that created this worktree: "codex", "claude", "ribhu", … or "unknown".
    var originAgent: String { (origin?.agent).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown" }

    struct AgentJoin: Decodable, Hashable {
        let agent: String?
        let session: String?
        let ts: String?

        private enum K: String, CodingKey { case agent, session, ts }
        init(from decoder: Decoder) throws {
            // Lenient: an object with agent/session/ts, or a bare string naming the agent.
            if let c = try? decoder.container(keyedBy: K.self) {
                agent = try? c.decode(String.self, forKey: .agent)
                session = try? c.decode(String.self, forKey: .session)
                ts = try? c.decode(String.self, forKey: .ts)
            } else {
                agent = try? decoder.singleValueContainer().decode(String.self)
                session = nil
                ts = nil
            }
        }
    }

    var repoName: String { repo_name ?? (repo as NSString).lastPathComponent }
    var isMain: Bool { main_checkout == true }
    /// Coding-agent processes only; dev servers, shells and helpers are not agents.
    /// Distinct agent sessions working here: from `agents_live` (ancestor-attributed) when the skill
    /// provides it, else agent processes whose own cwd is here.
    var liveAgents: [AgentRef] {
        if let a = agents_live { return a }
        return (live ?? []).filter { agentKinds_.contains($0.kind) }.map { AgentRef(pid: $0.pid, kind: $0.kind) }
    }
    var liveCount: Int { liveAgents.count }
    /// Processes here that are not agents themselves (dev servers, builds, agent tool shells).
    var otherProcCount: Int { (live ?? []).filter { !agentKinds_.contains($0.kind) }.count }
    var joinedCount: Int { agents?.count ?? 0 }
    /// Agents working here: declared joins, or live agent processes, whichever is larger —
    /// a crashed agent leaves a stale join, an agent that never joined still shows as a process.
    var agentCount: Int { max(liveCount, joinedCount) }
    var dirtyCount: Int { (dirty?.tracked ?? 0) + (dirty?.untracked ?? 0) }
    var isStale: Bool { ["stale", "gone"].contains(status ?? "") }
    var isReady: Bool { verdict == "CANDIDATE" }
    var isIdle: Bool { (idle_days ?? 0) >= 7 && agentCount == 0 }

    /// Distinct agent kinds at work here (processes first, then declared joins).
    var agentKinds: [String] {
        var seen: [String] = []
        for p in liveAgents where !seen.contains(p.kind) { seen.append(p.kind) }
        for j in (agents ?? [:]).values { if let a = j.agent, !seen.contains(a) { seen.append(a) } }
        return seen
    }

    /// Sort key: what needs eyes first.
    var rank: Int {
        if isMain { return 0 }
        if agentCount > 0 { return 1 }
        if isReady { return 2 }
        if dirtyCount > 0 { return 3 }
        if isStale { return 5 }
        if isIdle { return 6 }
        return 4
    }
}

/// Process kinds from wtr.py that are coding agents.
let agentKinds_: Set<String> = ["claude", "codex", "gemini", "cursor", "opencode", "qwen", "copilot", "pi", "ribhu"]

struct WorktreeRepo: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let rows: [WorktreeRow]       // linked worktrees, sorted by rank
    let main: WorktreeRow?

    var liveCount: Int { rows.filter { $0.agentCount > 0 }.count }
    var readyCount: Int { rows.filter(\.isReady).count }
    var idleCount: Int { rows.filter(\.isIdle).count }
    var staleCount: Int { rows.filter(\.isStale).count }
    var buildBytes: Int64 { rows.compactMap(\.build_bytes).reduce(0, +) }
    var sizeBytes: Int64 { rows.compactMap(\.size_bytes).reduce(0, +) }
}

func groupWorktrees(_ rows: [WorktreeRow]) -> [WorktreeRepo] {
    let byRepo = Dictionary(grouping: rows, by: \.repo)
    // Two repos can share a folder name (e.g. Personal/AUriva and websites/AUriva): label those by parent/name.
    let nameCounts = Dictionary(grouping: byRepo.keys, by: { ($0 as NSString).lastPathComponent }).mapValues(\.count)
    func label(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard (nameCounts[name] ?? 0) > 1 else { return name }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return "\(parent)/\(name)"
    }
    return byRepo.map { path, rs in
        let main = rs.first(where: \.isMain)
        let linked = rs.filter { !$0.isMain }.sorted {
            $0.rank != $1.rank ? $0.rank < $1.rank : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return WorktreeRepo(path: path, name: label(path),
                            rows: linked, main: main)
    }
    .sorted { ($0.liveCount, $0.rows.count) > ($1.liveCount, $1.rows.count) }
}

enum WorktreeLoadError: Error, CustomStringConvertible {
    case scriptMissing(String)
    case failed(String)
    case timedOut(Int)
    case badJSON(String)

    var description: String {
        switch self {
        case .scriptMissing(let p): return "wtr.py not found at \((p as NSString).abbreviatingWithTildeInPath)"
        case .failed(let m): return m
        case .timedOut(let s): return "wtr.py took longer than \(s)s"
        case .badJSON(let m): return "unreadable output: \(m)"
        }
    }
}

/// Runs `wtr.py ls --json …` off the main thread. `deep` adds --sizes and --audit (slow:
/// walks every worktree on disk), so the app runs it rarely and keeps its fields between runs.
func loadWorktrees(deep: Bool, completion: @escaping (Result<[WorktreeRow], WorktreeLoadError>) -> Void) {
    let script = WTR_SCRIPT
    let roots = WTR_SCAN_ROOTS
    DispatchQueue.global(qos: .utility).async {
        let result = runWtr(script: script, roots: roots, deep: deep)
        DispatchQueue.main.async { completion(result) }
    }
}

private func runWtr(script: String, roots: [String], deep: Bool) -> Result<[WorktreeRow], WorktreeLoadError> {
    guard FileManager.default.isReadableFile(atPath: script) else { return .failure(.scriptMissing(script)) }
    var args = ["-I", script, "ls", "--json", "--stats", "--include-main"]
    if deep { args += ["--sizes", "--audit"] }
    let existingRoots = roots.filter { FileManager.default.fileExists(atPath: $0) }
    if !existingRoots.isEmpty { args += ["--scan"] + existingRoots }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    // GUI apps start with a bare PATH; git, lsof and du must resolve the same way they do in a shell.
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["WTR_NO_MIRROR"] = "1"
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return .failure(.failed("could not start python3: \(error.localizedDescription)")) }

    let limit = deep ? 900 : 90
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(limit), execute: killer)
    // Drain both pipes before waiting, or a large listing fills the pipe buffer and deadlocks.
    var errData = Data()
    let errQueue = DispatchQueue(label: "wtr.stderr")
    errQueue.async { errData = err.fileHandleForReading.readDataToEndOfFile() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    errQueue.sync {}

    if p.terminationReason == .uncaughtSignal { return .failure(.timedOut(limit)) }
    guard p.terminationStatus == 0 else {
        let msg = String(data: errData, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
        return .failure(.failed(msg))
    }
    do {
        return .success(try JSONDecoder().decode([WorktreeRow].self, from: data))
    } catch {
        return .failure(.badJSON(String(describing: error).prefix(160).description))
    }
}

/// Opens a terminal window in the worktree (Ghostty by default, else Terminal.app).
func openTerminal(at path: String) {
    if TERMINAL_APP.lowercased() == "ghostty",
       NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", "Ghostty", "--args", "--working-directory=\(path)"]
        try? p.run()
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", "Terminal", path]
    try? p.run()
}

/// Shell-quotes a path for copied commands.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The skill's guarded retire command (dry run unless the user adds --execute).
func retireCommand(for row: WorktreeRow) -> String {
    let dir = ((WTR_SCRIPT as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    return "python3 -I \(dir)/wtr_retire.py worktree \(shellQuote(row.worktree))"
}

func ageText(_ iso: String?) -> String? {
    guard let iso else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let d else { return nil }
    let s = Int(Date().timeIntervalSince(d))
    if s < 3600 { return "\(max(1, s / 60))m" }
    if s < 172800 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

// MARK: - Lifecycle stages

enum WTStage: String, CaseIterable, Identifiable {
    case working, inProgress, ready, idle, stale
    var id: String { rawValue }
    var label: String {
        switch self {
        case .working: return "working"
        case .inProgress: return "in progress"
        case .ready: return "ready"
        case .idle: return "idle 7d+"
        case .stale: return "stale"
        }
    }
    var title: String {
        switch self {
        case .working: return "Agents working now"
        case .inProgress: return "In progress"
        case .ready: return "Ready to retire"
        case .idle: return "Idle for a week or more"
        case .stale: return "Stale registrations"
        }
    }
    var subtitle: String {
        switch self {
        case .working: return "a live agent process or a declared join"
        case .inProgress: return "work not yet on main"
        case .ready: return "on main, clean, no agent"
        case .idle: return "no agent, no activity in 7 days"
        case .stale: return "git knows them, the folder doesn't"
        }
    }
}

extension WorktreeRow {
    var stage: WTStage {
        if isStale { return .stale }
        if agentCount > 0 { return .working }
        if isReady { return .ready }
        if isIdle { return .idle }
        return .inProgress
    }
    /// Retirement gates as the drill-in shows them (the audit's verdict is the authority).
    var gates: [(ok: Bool, text: String)] {
        var g: [(Bool, String)] = []
        if isReady { g.append((true, "code is on main")) }
        else if let a = ahead, a > 0 { g.append((false, "\(a) commit\(a == 1 ? "" : "s") not on main yet")) }
        else if verdict == nil { g.append((false, "delivery not audited yet (runs with sizes)")) }
        else { g.append((false, "audit says keep")) }
        g.append(dirtyCount == 0 ? (true, "no uncommitted files") : (false, "\(dirtyCount) uncommitted"))
        g.append(agentCount == 0 ? (true, "no agent working") : (false, "\(agentCount) agent\(agentCount == 1 ? "" : "s") working"))
        g.append(status == "mapped" ? (true, "owner recorded") : (false, "owner not recorded"))
        return g
    }
}

// MARK: - Needs you

struct NeedItem: Identifiable {
    enum Action { case showReady(repo: String), copy(String), terminal(String) }
    let id: String
    let title: String
    let detail: String
    let actionLabel: String
    let action: Action
}

/// Live-worktree cap from the skill's ledger config (`cap`), default 15.
func worktreeCap() -> Int {
    let path = NSHomeDirectory() + "/.agents/ledger/config.json"
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cap = obj["cap"] as? Int, cap > 0 else { return 15 }
    return cap
}

func needsYou(_ repos: [WorktreeRepo], cap: Int) -> [NeedItem] {
    // Few and actionable: one line for everything ready to retire, one per repo over its cap.
    // "Main checkout is behind" stays in Branches and the drill-in: it is only as true as the last fetch.
    var items: [NeedItem] = []
    let auditDir = ((WTR_SCRIPT as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    let readyRepos = repos.filter { $0.readyCount > 0 }
    let readyCount = readyRepos.map(\.readyCount).reduce(0, +)
    if readyCount > 0 {
        let bytes = readyRepos.flatMap { $0.rows.filter(\.isReady) }.compactMap(\.size_bytes).reduce(0, +)
        let whereText = readyRepos.count == 1 ? "in \(readyRepos[0].name)" : "across \(readyRepos.count) repos"
        let free = bytes > 0 ? " · \(byteFormatter.string(fromByteCount: bytes)) to free" : ""
        items.append(NeedItem(id: "ready", title: "\(readyCount) ready to retire \(whereText)",
                              detail: "on main, clean, no agent\(free)", actionLabel: "Review",
                              action: .showReady(repo: readyRepos.count == 1 ? readyRepos[0].id : "")))
    }
    for r in repos.sorted(by: { $0.rows.count > $1.rows.count }) {
        let live = r.rows.filter { !$0.isStale }.count
        guard live > cap else { continue }
        items.append(NeedItem(id: "cap-\(r.id)", title: "\(r.name): \(live) worktrees, cap \(cap)",
                              detail: "agents won't create new ones here until some retire", actionLabel: "Copy Audit",
                              action: .copy("python3 -I \(auditDir)/wtr_audit.py \(shellQuote(r.path))")))
    }
    return Array(items.prefix(3))
}
