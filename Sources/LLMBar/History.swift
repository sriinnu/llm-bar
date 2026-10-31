import Foundation

// A small local history so the Agents timeline and the 14-day trend are real, not guessed.
// Each fast refresh appends one JSON line (who is live where, plus counts) to
// ~/Library/Application Support/LLMBar/worktree-history.jsonl. Lines older than 14 days are
// dropped once a day. ~150 bytes per agent per sample; at 10-minute refreshes that is well
// under 1 MB for two weeks. Nothing leaves the machine.

struct HistorySample: Codable {
    struct Live: Codable, Hashable { let kind: String; let pid: Int; let worktree: String; let name: String; let repo: String }
    let ts: Date
    let total: Int
    let ready: Int
    let live: [Live]
}

enum WorktreeHistory {
    static let keepDays = 14
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("worktree-history.jsonl")
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
    private static let queue = DispatchQueue(label: "llmbar.history")

    static func record(_ rows: [WorktreeRow]) {
        var live: [HistorySample.Live] = []
        for r in rows {
            for a in r.liveAgents {
                live.append(.init(kind: a.kind, pid: a.pid, worktree: r.worktree, name: r.name, repo: r.repoName))
            }
        }
        let sample = HistorySample(ts: Date(),
                                   total: rows.filter { !$0.isMain && !$0.isStale }.count,
                                   ready: rows.filter(\.isReady).count,
                                   live: live)
        queue.async {
            guard var line = try? encoder.encode(sample) else { return }
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: url)
            }
            pruneIfDue()
        }
    }

    /// Samples newer than `since`, oldest first.
    static func load(since: Date) -> [HistorySample] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(HistorySample.self, from: Data($0)) }
                .filter { $0.ts >= since }
        }
    }

    private static var lastPrune: Date? = nil
    private static func pruneIfDue() {
        if let p = lastPrune, Date().timeIntervalSince(p) < 86400 { return }
        lastPrune = Date()
        guard let data = try? Data(contentsOf: url) else { return }
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        let kept = data.split(separator: 0x0A).filter { line in
            (try? decoder.decode(HistorySample.self, from: Data(line)))?.ts ?? .distantPast >= cutoff
        }
        var out = Data()
        for l in kept { out.append(contentsOf: l); out.append(0x0A) }
        try? out.write(to: url, options: .atomic)
    }
}

// MARK: - Derived views

/// One bar on an agent's 24 h lane: a worktree it was seen in, from first to last consecutive sample.
struct LaneSpan: Identifiable {
    let id = UUID()
    let name: String
    let repo: String
    let start: Date
    let end: Date
    let liveNow: Bool
}

struct AgentLane: Identifiable {
    var id: String { kind }
    let kind: String
    let sessions: Int
    let spans: [LaneSpan]
    var liveNow: Bool { spans.contains(where: \.liveNow) }
}

/// Builds per-agent lanes from samples. Two samples further apart than `gap` split a span.
func agentLanes(_ samples: [HistorySample], now: Date = Date(), gap: TimeInterval = 25 * 60) -> [AgentLane] {
    struct Key: Hashable { let kind: String; let worktree: String }
    var spans: [Key: [(start: Date, end: Date, name: String, repo: String)]] = [:]
    var pids: [String: Set<Int>] = [:]
    for s in samples {
        for l in Set(s.live.map { Key(kind: $0.kind, worktree: $0.worktree) }) {
            let meta = s.live.first { $0.kind == l.kind && $0.worktree == l.worktree }!
            pids[l.kind, default: []].formUnion(s.live.filter { $0.kind == l.kind }.map(\.pid))
            if var list = spans[l], let last = list.last, s.ts.timeIntervalSince(last.end) <= gap {
                list[list.count - 1].end = s.ts
                spans[l] = list
            } else {
                spans[l, default: []].append((s.ts, s.ts, meta.name, meta.repo))
            }
        }
    }
    let latest = samples.last
    let liveNow = Set((latest?.live ?? []).map { Key(kind: $0.kind, worktree: $0.worktree) })
    let fresh = latest.map { now.timeIntervalSince($0.ts) < gap } ?? false
    var byKind: [String: [LaneSpan]] = [:]
    for (k, list) in spans {
        for sp in list {
            byKind[k.kind, default: []].append(LaneSpan(name: sp.name, repo: sp.repo, start: sp.start, end: sp.end,
                                                        liveNow: fresh && liveNow.contains(k) && sp.end == latest?.ts))
        }
    }
    return byKind.map { AgentLane(kind: $0.key, sessions: pids[$0.key]?.count ?? 0, spans: $0.value.sorted { $0.start < $1.start }) }
        .sorted { ($0.liveNow ? 0 : 1, -$0.spans.count) < ($1.liveNow ? 0 : 1, -$1.spans.count) }
}

/// Daily maximum of live worktrees for the last `days` days (nil where no sample exists).
func dailyTotals(_ samples: [HistorySample], days: Int = 14, now: Date = Date()) -> [Int?] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: now)
    return (0..<days).reversed().map { back in
        let day = cal.date(byAdding: .day, value: -back, to: today)!
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        return samples.filter { $0.ts >= day && $0.ts < next }.map(\.total).max()
    }
}
