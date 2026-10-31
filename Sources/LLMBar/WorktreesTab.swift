import AppKit
import SwiftUI

// The Worktrees tab: a header of numbers, a "Needs you" strip (only when something does),
// a view switcher (Lifecycle · Agents · Branches · Disk), and a drill-in for any row.
// Every view reads the same rows; themes only change the look.

enum WTView: String, CaseIterable, Identifiable {
    case lifecycle, agents, branches, disk
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lifecycle: return "Lifecycle"
        case .agents: return "Agents"
        case .branches: return "Branches"
        case .disk: return "Disk"
        }
    }
}

struct WorktreesTab: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.theme) private var theme
    @State private var selected: String? = nil
    @State private var stage: WTStage? = nil
    @State private var stageRepo: String? = nil

    private var view: WTView { WTView(rawValue: settings.worktreeView) ?? .lifecycle }

    var body: some View {
        let rows = state.worktreeRows
        if let path = selected, let row = rows.first(where: { $0.worktree == path }) {
            WorktreeDetailView(row: row, onBack: { selected = nil })
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    emptyState
                } else {
                    KPIHeader(state: state)
                    let needs = needsYou(state.worktreeRepos, cap: worktreeCap())
                    if !needs.isEmpty { NeedsYouStrip(items: needs, onShowReady: showReady) }
                    switcher
                    Band {
                    switch view {
                    case .lifecycle:
                        LifecycleView(rows: rows, stage: $stage, repoFilter: $stageRepo, onSelect: { selected = $0 })
                    case .agents:
                        let day = state.worktreeHistory.filter { $0.ts > Date().addingTimeInterval(-86400) }
                        if day.count >= 2 {
                            AgentTimelineView(lanes: agentLanes(day), rows: rows, onSelect: { selected = $0 })
                        } else {
                            AgentsView(rows: rows, onSelect: { selected = $0 })
                        }
                    case .branches:
                        BranchesView(repos: state.worktreeRepos, onSelect: { selected = $0 })
                    case .disk:
                        DiskView(state: state, onSelect: { selected = $0 })
                    }
                    }
                }
                statusLine
            }
        }
    }

    private func showReady(_ repo: String) {
        settings.worktreeView = WTView.lifecycle.rawValue
        stage = .ready
        stageRepo = repo.isEmpty ? nil : repo
    }

    @ViewBuilder
    private var switcher: some View {
        if theme.nativeControls {
            Picker("", selection: Binding(get: { view }, set: { settings.worktreeView = $0.rawValue })) {
                ForEach(WTView.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 16) {
                ForEach(WTView.allCases) { v in
                    Button(action: { settings.worktreeView = v.rawValue }) {
                        Text(theme.id == .terminal ? v.label.lowercased() : v.label)
                            .font(.subheadline.weight(v == view ? .semibold : .regular))
                            .foregroundStyle(v == view ? AnyShapeStyle(theme.id == .editorial ? Color.primary : theme.accent) : AnyShapeStyle(.secondary))
                            .padding(.vertical, 4)
                            .overlay(alignment: .bottom) {
                                if v == view { Rectangle().fill(theme.id == .editorial ? Color.primary : theme.accent).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = state.worktreeError {
                Text("Couldn't list worktrees").font(.callout.weight(.semibold))
                Text(err).font(.subheadline).foregroundStyle(.secondary)
            } else if state.worktreesLoadedAt == nil {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Finding worktrees…").font(.callout) }
            } else {
                Text("No worktrees found").font(.callout.weight(.semibold))
                Text("Repos are found from your agents' worktree folders. Add other folders in Settings → Worktrees.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Text(statusText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if state.worktreeLoading {
                ProgressView().controlSize(.mini)
            } else {
                Button(action: { state.refreshWorktrees(deep: NSEvent.modifierFlags.contains(.option)) }) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.footnote)
                }
                .buttonStyle(.borderless)
                .help("Refresh (⌥-click also measures sizes and runs the audit — slow)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        var t = state.worktreesLoadedAt.map { "listed \(relativeShort($0))" } ?? "not listed yet"
        if let s = state.worktreeSizesAt { t += " · sizes \(relativeShort(s))" } else { t += " · sizes not measured yet" }
        if let e = state.worktreeError, !state.worktreeRows.isEmpty { t += " · refresh failed: \(e)" }
        return t
    }
}

func relativeShort(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60) min ago" }
    return "\(s / 3600) h ago"
}

// MARK: - Header

private struct KPIHeader: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        let linked = state.worktreeRows.filter { !$0.isMain && !$0.isStale }
        let repos = Set(state.worktreeRows.map(\.repo)).count
        let live = Set(state.worktreeRows.flatMap { $0.liveAgents.map(\.pid) }).count
        let ready = linked.filter(\.isReady).count
        let bytes = state.worktreeRows.compactMap(\.size_bytes).reduce(0, +)
        if theme.id == .editorial {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text("\(linked.count)")
                    .font(.system(size: 56, weight: .heavy))
                    .tracking(-2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("worktrees in \(repos) repos").font(.callout)
                    if ready > 0 { Text("\(ready) ready to retire").font(.callout.weight(.semibold)).foregroundStyle(theme.accent) }
                    Text(live == 1 ? "1 agent working" : "\(live) agents working").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary).frame(height: 2).padding(.horizontal, 16) }
        } else {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    kpi("\(linked.count)", "worktrees", nil)
                    let totals = dailyTotals(state.worktreeHistory)
                    if totals.compactMap({ $0 }).count >= 2 { Sparkline(values: totals).padding(.horizontal, 8) }
                }
                kpi("\(live)", live == 1 ? "agent live" : "agents live", live > 0 ? theme.live : nil)
                kpi("\(ready)", "ready", ready > 0 ? theme.ready : nil)
                kpi(bytes > 0 ? byteFormatter.string(fromByteCount: bytes) : "—", "on disk", nil)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }

    private func kpi(_ value: String, _ label: String, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: theme.bigNumberWeight))
                .monospacedDigit()
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

// MARK: - Needs you

private struct NeedsYouStrip: View {
    let items: [NeedItem]
    let onShowReady: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(theme.id == .terminal ? "needs you" : "Needs you")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(items.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.danger)
            }
            .padding(.horizontal, theme.band == nil ? 16 : 20)
            .padding(.top, 4)
            .padding(.bottom, 4)
            VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Hairline(inset: 12) }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.body.weight(.semibold)).lineLimit(1)
                        Text(item.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button(item.actionLabel) { run(item.action) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            }
            .background {
                if let band = theme.band {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(band)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.hairline, lineWidth: 1))
                }
            }
            .padding(.horizontal, theme.band == nil ? 0 : 16)
        }
        .padding(.bottom, 8)
    }

    private func run(_ a: NeedItem.Action) {
        switch a {
        case .showReady(let repo): onShowReady(repo)
        case .copy(let text): copy(text)
        case .terminal(let path): openTerminal(at: path)
        }
    }
}

// MARK: - Shared row

struct WTRow: View {
    let row: WorktreeRow
    var showRepo = true
    var originTag = false
    var trailing: AnyView? = nil
    let onSelect: (String) -> Void
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    TruncatedName(text: row.name, font: .body.weight(.medium))
                    if row.isMain { Text("main checkout").font(.footnote).foregroundStyle(.secondary) }
                    if originTag && row.originAgent != "unknown" {
                        Text(row.originAgent).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                if !settings.compact {
                    Text(meta).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if row.agentCount > 0 { AgentBadge(row: row) }
                if let trailing { trailing }
                else if let d = drift { Text(d).font(.footnote).monospacedDigit().foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .fixedSize()
            .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, settings.compact ? 3 : 5)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(row.worktree) }
        .contextMenu { WTRowMenu(row: row) }
        .help(row.worktree)
    }

    private var dot: Color {
        switch row.stage {
        case .working: return theme.live
        case .ready: return theme.ready
        case .stale: return theme.danger.opacity(0.6)
        case .idle: return Color.secondary.opacity(0.35)
        case .inProgress: return row.dirtyCount > 0 ? theme.warn : Color.secondary.opacity(0.6)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if showRepo { parts.append(row.repoName) }
        if let b = row.branch { parts.append(row.base?.ref.map { "\(b) ← \($0)" } ?? b) }
        if row.dirtyCount > 0 { parts.append("\(row.dirtyCount) uncommitted") }
        if let s = row.size_bytes, s > 0 { parts.append(byteFormatter.string(fromByteCount: s)) }
        if let a = ageText(row.head_ts) { parts.append(a) }
        if settings.showAdvice, let adv = row.advice, !adv.shortLabel.isEmpty { parts.append("Jev: \(adv.shortLabel)") }
        return parts.joined(separator: " · ")
    }

    private var drift: String? {
        guard let a = row.ahead, let b = row.behind else { return nil }
        if a == 0 && b == 0 { return "=" }
        return [a > 0 ? "↑\(a)" : nil, b > 0 ? "↓\(b)" : nil].compactMap { $0 }.joined(separator: " ")
    }
}

struct WTRowMenu: View {
    let row: WorktreeRow
    var body: some View {
        Button("Open in \(TERMINAL_APP)") { openTerminal(at: row.worktree) }
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(row.worktree, inFileViewerRootedAtPath: "") }
        Divider()
        Button("Copy Path") { copy(row.worktree) }
        if let b = row.branch { Button("Copy Branch") { copy(b) } }
        if row.isReady {
            Divider()
            Button("Copy Retire Command (dry run)") { copy(retireCommand(for: row)) }
        }
    }
}

/// Agent count with a person glyph; green when processes are live.
struct AgentBadge: View {
    let row: WorktreeRow
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: row.agentCount > 1 ? "person.2.fill" : "person.fill").font(.caption2)
            Text(row.agentKinds.first.map { row.agentCount > 1 ? "\(row.agentCount)" : $0 } ?? "\(row.agentCount)")
                .font(.footnote.weight(.medium))
        }
        .foregroundStyle(row.liveCount > 0 ? theme.live : Color.secondary)
        .help(row.agentKinds.joined(separator: ", "))
    }
}

// MARK: - Lifecycle

private struct LifecycleView: View {
    let rows: [WorktreeRow]
    @Binding var stage: WTStage?
    @Binding var repoFilter: String?
    let onSelect: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var showAll = false

    private var linked: [WorktreeRow] { rows.filter { !$0.isMain || $0.agentCount > 0 } }
    private func count(_ s: WTStage) -> Int { linked.filter { $0.stage == s }.count }
    private var current: WTStage {
        if let stage { return stage }
        return [.working, .ready, .inProgress, .idle, .stale].first { count($0) > 0 } ?? .inProgress
    }

    var body: some View {
        let cur = current
        let list = linked.filter { $0.stage == cur && (repoFilter == nil || $0.repo == repoFilter) }
            .sorted { ($0.repoName, $0.name) < ($1.repoName, $1.name) }
        let shown = showAll ? list : Array(list.prefix(25))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(WTStage.allCases) { s in
                    Button(action: { stage = s; repoFilter = nil; showAll = false }) {
                        VStack(spacing: 0) {
                            Text("\(count(s))").font(.headline.weight(.bold)).monospacedDigit()
                                .foregroundStyle(color(s))
                            Text(s.label).font(.caption2).lineLimit(1)
                                .foregroundStyle(s == cur ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(s == cur ? color(s).opacity(0.14) : Color.clear)
                        .overlay(alignment: .bottom) { if s == cur { Rectangle().fill(color(s)).frame(height: 2) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if s != WTStage.allCases.last { Rectangle().fill(theme.hairline).frame(width: 1) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: theme.id == .editorial ? 0 : 6).stroke(theme.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: theme.id == .editorial ? 0 : 6))
            .padding(.horizontal, 16)
            .padding(.top, 8)

            GeometryReader { geo in
                let total = max(1, linked.count)
                HStack(spacing: 1) {
                    ForEach(WTStage.allCases) { s in
                        Rectangle().fill(color(s).opacity(s == .idle ? 0.35 : 0.85))
                            .frame(width: max(0, geo.size.width * CGFloat(count(s)) / CGFloat(total) - 1))
                    }
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 16)
            .padding(.top, 5)

            HStack(alignment: .firstTextBaseline) {
                Text(cur.title).font(.callout.weight(.semibold))
                if let r = repoFilter {
                    Button(action: { repoFilter = nil }) {
                        Text("\((r as NSString).lastPathComponent) ✕").font(.footnote)
                    }.buttonStyle(.borderless)
                }
                Spacer()
                GroupMenu()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if list.isEmpty {
                Text(cur == .ready && rows.allSatisfy({ $0.verdict == nil })
                     ? "Not audited yet. The audit runs with the size pass (⌥-click refresh)."
                     : "Nothing here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            GroupedRows(rows: shown, onSelect: onSelect)
            if list.count > shown.count {
                Button("Show all \(list.count)") { showAll = true }
                    .buttonStyle(.borderless).font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            if cur == .ready && !list.isEmpty {
                Hairline()
                HStack {
                    let bytes = list.compactMap(\.size_bytes).reduce(0, +)
                    Text(bytes > 0 ? "\(byteFormatter.string(fromByteCount: bytes)) would free" : "\(list.count) to retire")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Retire Commands") { copy(list.map(retireCommand(for:)).joined(separator: "\n")) }
                        .controlSize(.small)
                        .help("Dry runs. Add --execute to each to actually remove.")
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
            }
        }
    }

    private func color(_ s: WTStage) -> Color {
        switch s {
        case .working: return theme.live
        case .inProgress: return theme.warn
        case .ready: return theme.ready
        case .idle: return Color.secondary
        case .stale: return theme.danger
        }
    }
}

// MARK: - Agents (live now; the 24 h timeline arrives with the history log)

private struct AgentsView: View {
    let rows: [WorktreeRow]
    let onSelect: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let byKind = groups()
        VStack(alignment: .leading, spacing: 0) {
            if byKind.isEmpty {
                Text("No agent is working in any worktree right now.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(14)
            }
            ForEach(byKind, id: \.kind) { g in
                HStack(alignment: .firstTextBaseline) {
                    Text(g.kind).font(.callout.weight(.semibold)).foregroundStyle(theme.live)
                    Text("\(g.sessions) session\(g.sessions == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
                ForEach(g.rows) { row in WTRow(row: row, onSelect: onSelect) }
            }
            let quiet = rows.filter { !$0.isMain && $0.agentCount == 0 && !$0.isStale }.count
            Hairline().padding(.top, 6)
            Text("Nobody in \(quiet) worktree\(quiet == 1 ? "" : "s")")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private struct Group { let kind: String; let sessions: Int; let rows: [WorktreeRow] }

    private func groups() -> [Group] {
        var rowsByKind: [String: [WorktreeRow]] = [:]
        var pidsByKind: [String: Set<Int>] = [:]
        for r in rows {
            for a in r.liveAgents {
                pidsByKind[a.kind, default: []].insert(a.pid)
                if !(rowsByKind[a.kind]?.contains(where: { $0.id == r.id }) ?? false) { rowsByKind[a.kind, default: []].append(r) }
            }
            for j in (r.agents ?? [:]).values {
                guard let k = j.agent, !(rowsByKind[k]?.contains(where: { $0.id == r.id }) ?? false) else { continue }
                rowsByKind[k, default: []].append(r)
            }
        }
        return rowsByKind.map { Group(kind: $0.key, sessions: max(1, pidsByKind[$0.key]?.count ?? 0), rows: $0.value) }
            .sorted { $0.sessions > $1.sessions }
    }
}

// MARK: - Branches

private struct BranchesView: View {
    let repos: [WorktreeRepo]
    let onSelect: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var repoID: String? = nil
    @State private var showAll = false

    var body: some View {
        let candidates = repos.filter { !$0.rows.isEmpty }
        let repo = candidates.first { $0.id == repoID } ?? candidates.first
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    ForEach(candidates) { r in
                        Button { repoID = r.id } label: {
                            if r.id == repo?.id { Label("\(r.name)  \(r.rows.count)", systemImage: "checkmark") }
                            else { Text("\(r.name)  \(r.rows.count)") }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(repo?.name ?? "Repo").font(.headline)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose a repo")
                Spacer()
                if let m = repo?.main, let f = ageText(m.fetched_ts) {
                    Text("fetched \(f) ago").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if let repo {
                let all = repo.rows.filter { !$0.isStale && !$0.isIdle }.sorted { ($0.ahead ?? 0) > ($1.ahead ?? 0) }
                let rows = showAll ? all : Array(all.prefix(20))
                let maxAhead = max(1, rows.compactMap(\.ahead).max() ?? 1)
                HStack(spacing: 6) {
                    Circle().fill(Color.primary).frame(width: 11, height: 11)
                    Text(repo.main?.against ?? "origin/main").font(.body.weight(.semibold).monospaced())
                    if let m = repo.main, let b = m.branch { Text("main checkout on \(b)").font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 16).padding(.bottom, 2)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    MetroRow(row: row, maxAhead: maxAhead, last: i == rows.count - 1, onSelect: onSelect)
                }
                if all.count > rows.count {
                    Button("Show all \(all.count)") { showAll = true }.buttonStyle(.borderless).font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
                let hidden = repo.rows.count - all.count
                if hidden > 0 {
                    Text("\(hidden) idle or stale not drawn").font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
            }
        }
    }
}

private struct MetroRow: View {
    let row: WorktreeRow
    let maxAhead: Int
    let last: Bool
    let onSelect: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let color: Color = row.agentCount > 0 ? theme.live : (row.dirtyCount > 0 ? theme.warn : theme.accent)
        HStack(alignment: .center, spacing: 0) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.primary).frame(width: 2.5).frame(maxHeight: last ? 22 : .infinity, alignment: .top)
            }
            .frame(width: 11)
            .frame(maxHeight: .infinity, alignment: .top)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addQuadCurve(to: CGPoint(x: 12, y: 21), control: CGPoint(x: 0, y: 21))
            }
            .stroke(color, lineWidth: 2.5)
            .frame(width: 12, height: 22)
            .offset(x: -5.5, y: -10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // sqrt scale: one branch 800 ahead must not flatten the rest into stubs
                    Capsule().fill(color).frame(width: max(6, 120 * sqrt(CGFloat(row.ahead ?? 0)) / sqrt(CGFloat(maxAhead))), height: 3)
                    Text("+\(row.ahead ?? 0)").font(.footnote.weight(.semibold)).foregroundStyle(color)
                    if let b = row.behind, b > 0 { Text("−\(b)").font(.footnote).foregroundStyle(.secondary) }
                }
                HStack(spacing: 4) {
                    TruncatedName(text: row.name, font: .body.weight(.medium))
                    if row.dirtyCount > 0 { Text("· \(row.dirtyCount) uncommitted").font(.footnote).foregroundStyle(theme.warn) }
                    if row.agentCount > 0 { AgentBadge(row: row) }
                }
            }
            .padding(.leading, -4)
            Spacer()
        }
        .frame(height: 42)
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(row.worktree) }
        .contextMenu { WTRowMenu(row: row) }
    }
}

// MARK: - Disk

private struct DiskView: View {
    @ObservedObject var state: AppState
    let onSelect: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var openRepo: String? = nil

    var body: some View {
        let repos = state.worktreeRepos.map { r in (r, r.sizeBytes + (r.main?.size_bytes ?? 0)) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let total = repos.map(\.1).reduce(0, +)
        let build = state.worktreeRows.compactMap(\.build_bytes).reduce(0, +)
        let ready = state.worktreeRows.filter(\.isReady).compactMap(\.size_bytes).reduce(0, +)
        VStack(alignment: .leading, spacing: 0) {
            if total == 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sizes not measured yet").font(.callout.weight(.semibold))
                    Text("Measuring walks every worktree (about 20 s). It skips dependency folders, which are hard links into one shared store.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Measure Now") { state.refreshWorktrees(deep: true) }.controlSize(.small).disabled(state.worktreeLoading)
                }
                .padding(14)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(byteFormatter.string(fromByteCount: total)).font(.system(size: 20, weight: theme.bigNumberWeight))
                    Text("excluding dependencies").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.top, 10)
                Text("\(byteFormatter.string(fromByteCount: build)) build output · \(byteFormatter.string(fromByteCount: ready)) in worktrees ready to retire")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                let maxRepo = repos.first?.1 ?? 1
                ForEach(repos, id: \.0.id) { r, bytes in
                    let readyBytes = r.rows.filter(\.isReady).compactMap(\.size_bytes).reduce(0, +)
                    let dirtyBytes = r.rows.filter { $0.dirtyCount > 0 && !$0.isReady }.compactMap(\.size_bytes).reduce(0, +)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(r.name).font(.body.weight(.medium))
                            Spacer()
                            Text(byteFormatter.string(fromByteCount: bytes)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            let w = geo.size.width * CGFloat(bytes) / CGFloat(maxRepo)
                            HStack(spacing: 1) {
                                Rectangle().fill(theme.ready).frame(width: w * CGFloat(readyBytes) / CGFloat(max(bytes, 1)))
                                Rectangle().fill(theme.warn.opacity(0.7)).frame(width: w * CGFloat(dirtyBytes) / CGFloat(max(bytes, 1)))
                                Rectangle().fill(Color.secondary.opacity(0.35))
                            }
                            .frame(width: max(2, w), alignment: .leading)
                        }
                        .frame(height: 6)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture { openRepo = openRepo == r.id ? nil : r.id }
                    if openRepo == r.id {
                        ForEach(r.rows.filter { ($0.size_bytes ?? 0) > 0 }.sorted { ($0.size_bytes ?? 0) > ($1.size_bytes ?? 0) }.prefix(10)) { row in
                            WTRow(row: row, showRepo: false, onSelect: onSelect)
                        }
                    }
                }
                HStack(spacing: 12) {
                    legend(theme.ready, "ready to retire")
                    legend(theme.warn.opacity(0.7), "uncommitted")
                    legend(Color.secondary.opacity(0.35), "other")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Rectangle().fill(c).frame(width: 9, height: 9); Text(t).font(.footnote).foregroundStyle(.secondary) }
    }
}

// MARK: - Drill-in

struct WorktreeDetailView: View {
    let row: WorktreeRow
    let onBack: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 3) { Image(systemName: "chevron.left").font(.footnote.weight(.semibold)); Text(row.repoName) }
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            .padding(.horizontal, 16).padding(.top, 10)
            Text(row.name).font(.title3.weight(.bold)).lineLimit(2)
                .padding(.horizontal, 16).padding(.top, 4)
            Text((row.worktree as NSString).abbreviatingWithTildeInPath)
                .font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 16).padding(.bottom, 8)
            Hairline()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                if let b = row.branch { fact("Branch", b, mono: true) }
                fact("Created from", baseText)
                fact("Created by", row.originAgent == "unknown" ? "not known" : row.originAgent + ((row.origin?.how).map { " (\($0))" } ?? ""))
                fact("Owner", ownerText)
                fact("Agents now", agentsText, color: row.agentCount > 0 ? theme.live : nil)
                fact("Versus main", driftText)
                fact("Last build", buildText)
                fact("Size", sizeText)
                if let p = row.purpose, !p.isEmpty { fact("Purpose", p) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Hairline()
            if AppSettings.shared.showAdvice, let adv = row.advice {
                AdviceBlock(advice: adv)
                Hairline()
            }
            Text("Retirement").font(.callout.weight(.semibold)).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            ForEach(Array(row.gates.enumerated()), id: \.offset) { _, g in
                HStack(spacing: 6) {
                    Image(systemName: g.ok ? "checkmark" : "xmark").font(.caption2.weight(.bold))
                        .foregroundStyle(g.ok ? theme.live : theme.warn)
                    Text(g.text).font(.subheadline)
                }
                .padding(.horizontal, 16).padding(.vertical, 1.5)
            }
            HStack(spacing: 6) {
                Button("Terminal") { openTerminal(at: row.worktree) }
                Button("Finder") { NSWorkspace.shared.selectFile(row.worktree, inFileViewerRootedAtPath: "") }
                Button("Copy Path") { copy(row.worktree) }
                if row.isReady { Button("Copy Retire") { copy(retireCommand(for: row)) } }
            }
            .controlSize(.small)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func fact(_ k: String, _ v: String, mono: Bool = false, color: Color? = nil) -> some View {
        GridRow {
            Text(k).font(.subheadline).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(v).font(.system(size: 11, design: mono ? .monospaced : theme.fontDesign))
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .lineLimit(2).textSelection(.enabled)
        }
    }

    private var baseText: String {
        guard let b = row.base, let ref = b.ref else { return "not recorded" }
        let sha = b.sha.map { " at " + String($0.prefix(7)) } ?? ""
        return ref + sha + (b.how == "contained-in" ? " (inferred)" : "")
    }
    private var ownerText: String {
        if let t = row.task { return "task \(t)" }
        switch row.status {
        case "born": return "created via git hook, no task recorded"
        case "main": return "main checkout"
        default: return "not recorded"
        }
    }
    private var agentsText: String {
        if row.agentCount == 0 { return "none" }
        return row.agentKinds.joined(separator: ", ") + (row.liveCount > 0 ? " · live" : " · joined")
    }
    private var driftText: String {
        guard let a = row.ahead, let b = row.behind else { return "unknown (no origin/main)" }
        var t = "\(a) ahead · \(b) behind \(row.against ?? "main")"
        if let f = ageText(row.fetched_ts) { t += " · fetched \(f) ago" }
        return t
    }
    private var buildText: String {
        guard let b = row.last_build else { return "not recorded" }
        return [b.label, b.status, ageText(b.ts).map { "\($0) ago" }].compactMap { $0 }.joined(separator: " · ")
    }
    private var sizeText: String {
        guard let s = row.size_bytes else { return "not measured yet" }
        var t = byteFormatter.string(fromByteCount: s)
        if let b = row.build_bytes, b > 0 { t += " · \(byteFormatter.string(fromByteCount: b)) build output" }
        return t
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - dev snapshot

/// `LLMBar --snapshot-worktrees rows.json out.png [dark] [theme=terminal] [view=branches] [detail=<name>]`
/// renders the tab bar + Worktrees tab from a saved `wtr.py ls --json` listing, then exits.
@MainActor
func snapshotWorktrees(input: String, output: String, options: [String]) -> Int32 {
    guard let data = FileManager.default.contents(atPath: input),
          let rows = try? JSONDecoder().decode([WorktreeRow].self, from: data) else {
        FileHandle.standardError.write("cannot read rows from \(input)\n".data(using: .utf8)!)
        return 2
    }
    func opt(_ k: String) -> String? { options.first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } }
    _ = NSApplication.shared
    let state = AppState()
    state.worktreeRows = rows
    state.worktreesLoadedAt = Date().addingTimeInterval(-120)
    if rows.contains(where: { $0.size_bytes != nil }) { state.worktreeSizesAt = Date().addingTimeInterval(-1500) }
    if options.contains("demo-history") {
        // Dev-only synthetic samples to exercise the timeline and trend renders.
        let now = Date()
        var samples: [HistorySample] = []
        for i in stride(from: 14 * 144, through: 0, by: -1) {
            let ts = now.addingTimeInterval(-Double(i) * 600)
            var live: [HistorySample.Live] = []
            if i < 40 { live.append(.init(kind: "ribhu", pid: 1, worktree: "/x/junban", name: "junban", repo: "junban")) }
            if i < 20 { live.append(.init(kind: "claude", pid: 2, worktree: "/x/llm-bar", name: "llm-bar", repo: "llm-bar")) }
            if i > 60 && i < 110 { live.append(.init(kind: "codex", pid: 3, worktree: "/x/omc", name: "operator-maincut-20261030", repo: "Personal/AUriva")) }
            if i > 90 && i < 130 { live.append(.init(kind: "codex", pid: 4, worktree: "/x/rns", name: "ribhu-native-service-20261030", repo: "ribhu")) }
            samples.append(HistorySample(ts: ts, total: 60 + (14 * 144 - i) / 40, ready: 3, live: live))
        }
        state.worktreeHistory = samples
    }
    let theme = Theme.of(ThemeID(rawValue: opt("theme") ?? "") ?? .native)
    AppSettings.shared.worktreeView = opt("view") ?? "lifecycle"
    let detail = opt("detail").flatMap { name in rows.first { $0.name == name }?.worktree }
    let view = SnapshotHost(state: state, detail: detail)
        .frame(width: 380)
        .themed(theme)
        .environment(\.colorScheme, theme.scheme ?? (options.contains("dark") ? .dark : .light))
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: (theme.scheme ?? (options.contains("dark") ? .dark : .light)) == .dark ? .darkAqua : .aqua)
    host.frame = NSRect(x: 0, y: 0, width: 380, height: 10)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    host.frame.size.height = min(host.fittingSize.height, 2400)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 3 }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return 3 }
    do { try png.write(to: URL(fileURLWithPath: output)) } catch { return 4 }
    print("rendered \(rows.count) rows → \(output)")
    return 0
}

private struct SnapshotHost: View {
    @ObservedObject var state: AppState
    let detail: String?
    var body: some View {
        VStack(spacing: 0) {
            TabBar(tabs: ContentView.Tab.allCases, current: .worktrees,
                   badges: [.lanes: ("2", true), .worktrees: ("\(state.worktreeRows.filter { !$0.isMain && !$0.isStale }.count)", false)],
                   select: { _ in })
                .padding(.top, 10)
            Hairline()
            if let detail, let row = state.worktreeRows.first(where: { $0.worktree == detail }) {
                WorktreeDetailView(row: row, onBack: {})
            } else {
                WorktreesTab(state: state)
            }
        }
    }
}


// MARK: - 14-day trend

struct Sparkline: View {
    let values: [Int?]
    @Environment(\.theme) private var theme
    var body: some View {
        let maxV = max(1, values.compactMap { $0 }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                Rectangle()
                    .fill(i == values.count - 1 ? theme.accent : Color.secondary.opacity(0.4))
                    .frame(width: 3, height: v.map { max(1.5, 14 * CGFloat($0) / CGFloat(maxV)) } ?? 1)
                    .opacity(v == nil ? 0.25 : 1)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .help("Live worktrees per day, last 14 days")
    }
}

// MARK: - Agents timeline (24 h, from the history log)

private struct AgentTimelineView: View {
    let lanes: [AgentLane]
    let rows: [WorktreeRow]
    let onSelect: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-86400)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Last 24 h").font(.callout.weight(.semibold))
                Spacer()
                Text("\(lanes.filter(\.liveNow).count) live now").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 10)
            HStack(spacing: 0) {
                Spacer().frame(width: 70)
                ForEach(["-24h", "-18h", "-12h", "-6h", "now"], id: \.self) { t in
                    Text(t).font(.caption2).foregroundStyle(.secondary)
                    if t != "now" { Spacer() }
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 2)
            ForEach(lanes) { lane in
                Hairline()
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lane.kind).font(.body.weight(.semibold))
                            .foregroundStyle(lane.liveNow ? theme.live : Color.primary)
                        Text(lane.liveNow ? "live" : "earlier").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(width: 70, alignment: .leading)
                    VStack(spacing: 3) {
                        ForEach(lane.spans) { sp in
                            GeometryReader { geo in
                                let w = geo.size.width
                                let x0 = w * CGFloat(max(0, sp.start.timeIntervalSince(start)) / 86400)
                                let x1 = w * CGFloat(min(86400, sp.end.timeIntervalSince(start)) / 86400)
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(sp.liveNow ? theme.live : theme.accent.opacity(0.45))
                                        .frame(width: max(4, x1 - x0))
                                        .offset(x: x0)
                                    Text("\(sp.repo) / \(sp.name)").font(.footnote).lineLimit(1)
                                        .padding(.leading, 4)
                                }
                            }
                            .frame(height: 16)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let r = rows.first(where: { $0.name == sp.name && $0.repoName == sp.repo }) { onSelect(r.worktree) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
            }
            let quiet = rows.filter { !$0.isMain && $0.agentCount == 0 && !$0.isStale }.count
            Hairline()
            Text("Nobody in \(quiet) worktree\(quiet == 1 ? "" : "s") right now")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}


// MARK: - Grouping (project → agent, agent → project)

struct GroupMenu: View {
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        Picker("Group", selection: Binding(get: { settings.worktreeGroup }, set: { settings.worktreeGroup = $0 })) {
            Image(systemName: "folder").help("Group by project").tag("project")
            Image(systemName: "person.2").help("Group by the agent that created it").tag("agent")
            Image(systemName: "list.bullet").help("No grouping").tag("none")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Group worktrees")
    }
}

/// Rows grouped by project or by creating agent; within a group, sorted by the other key.
struct GroupedRows: View {
    let rows: [WorktreeRow]
    let onSelect: (String) -> Void
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.theme) private var theme

    var body: some View {
        let mode = settings.worktreeGroup
        if mode == "none" {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Hairline(inset: 31) }
                WTRow(row: row, showRepo: true, originTag: true, onSelect: onSelect)
            }
        } else {
            let byAgent = mode == "agent"
            let groups = Dictionary(grouping: rows, by: { byAgent ? $0.originAgent : $0.repoName })
                .map { (key: $0.key, rows: $0.value.sorted {
                    let a = byAgent ? $0.repoName : $0.originAgent, b = byAgent ? $1.repoName : $1.originAgent
                    return a != b ? a < b : $0.name < $1.name
                }) }
                .sorted { ($0.key == "unknown" ? 1 : 0, -$0.rows.count, $0.key) < ($1.key == "unknown" ? 1 : 0, -$1.rows.count, $1.key) }
            ForEach(groups, id: \.key) { g in
                HStack(spacing: 6) {
                    if byAgent { AgentGlyph(agent: g.key) }
                    Text(g.key).font(.subheadline.weight(.semibold))
                    Text("\(g.rows.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if byAgent {
                        Text(Set(g.rows.map(\.repoName)).count == 1 ? g.rows[0].repoName : "\(Set(g.rows.map(\.repoName)).count) projects")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(Array(Set(g.rows.map(\.originAgent))).sorted().joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 3)
                ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Hairline(inset: 31) }
                    WTRow(row: row, showRepo: byAgent, originTag: !byAgent, onSelect: onSelect)
                }
            }
        }
    }
}

/// A small monochrome mark per agent kind (SF Symbols; letters for agents without one).
struct AgentGlyph: View {
    let agent: String
    var body: some View {
        let symbol: String? = [
            "claude": "sparkle", "codex": "chevron.left.forwardslash.chevron.right", "ribhu": "wind",
            "pi": "p.circle", "opencode": "curlybraces", "cline": "c.circle", "vscode": "chevron.left.slash.chevron.right",
            "cursor": "cursorarrow", "gemini": "diamond", "qwen": "q.circle", "copilot": "airplane", "grok": "x.circle",
            "manual": "person", "main": "house", "unknown": "questionmark.circle",
        ][agent]
        Image(systemName: symbol ?? "circle.dashed")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(width: 14)
    }
}


// MARK: - Jev suggestion (advisory: shown next to your controls, never wired to one)

struct AdviceBlock: View {
    let advice: WorktreeRow.Advice
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.footnote).foregroundStyle(.secondary)
                Text("Jev suggests").font(.headline)
                Spacer()
                Text("you decide").font(.footnote).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(advice.decisionLabel).font(.body.weight(.medium))
                if let c = advice.confidence {
                    Text("\(Int((c * 100).rounded()))% sure").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let a = advice.abandoned?.normalized {
                HStack(spacing: 8) {
                    Text("Abandoned").font(.subheadline).foregroundStyle(.secondary)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(a >= 0.6 ? theme.warn : Color.secondary.opacity(0.55))
                                .frame(width: g.size.width * CGFloat(min(max(a, 0), 1)))
                        }
                    }
                    .frame(height: 5)
                    Text("\(Int((a * 100).rounded()))%").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let p = advice.purpose?.text, !p.isEmpty {
                HStack(spacing: 4) {
                    Text("Purpose").font(.subheadline).foregroundStyle(.secondary)
                    Text(p).font(.subheadline)
                }
            }
            Text([advice.model, ageText(advice.ts).map { "\($0) ago" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
