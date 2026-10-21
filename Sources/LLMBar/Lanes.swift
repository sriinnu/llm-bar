import AppKit
import Foundation

// Cloud lanes = the Claude Code provider launchers defined in claude_config.zsh
// (zai, deepseekflash, kimi-us, siliconflow, …). The app never sources that file:
// it reads the `lcp-help` text block for names + descriptions, reads a status
// cache written by scripts/lane-status.zsh, and launches a lane in a terminal.
// Everything is path-overridable so this stays usable for anyone with a
// similar dotfile, not just one machine.

let CLAUDE_CONFIG_PATH = env("LLMBAR_CLAUDE_CONFIG", default: NSHomeDirectory() + "/.claude_config.zsh")
let LANE_STATUS_PATH = env("LLMBAR_LANE_STATUS", default: NSHomeDirectory() + "/.cache/lcp/lane-status.json")
let LANE_PROBE_PATH: String = {
    if let p = ProcessInfo.processInfo.environment["LLMBAR_LANE_PROBE"] { return p }
    // Default: scripts/lane-status.zsh next to the real config file (follow the ~/.claude_config.zsh symlink).
    let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: CLAUDE_CONFIG_PATH)) ?? CLAUDE_CONFIG_PATH
    let dir = (resolved as NSString).deletingLastPathComponent
    return dir + "/scripts/lane-status.zsh"
}()
let TERMINAL_APP = env("LLMBAR_TERMINAL", default: "Ghostty")

struct LaneEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let group: String
}

struct LaneStatus: Decodable {
    let id: String
    let status: String      // ok | auth | balance | ratelimit | down | nokey | error
    let http: Int
    let ms: Int
    let model: String
    let detail: String?
    let shared_with: String?
}

struct LaneStatusDoc: Decodable {
    let probed_at: String
    let lanes: [String: LaneStatus]
}

// Helpers that live in the config but are not Claude Code sessions.
private let laneExclusions: Set<String> = [
    "or-models", "vai-models", "hf", "orf-update", "sf-models", "qwen-image", "qwen-video",
    "llp-stats", "llp-history", "llp-which", "llp-reset", "lcp-help", "lcp",
]

/// Parses the `lcp-help` heredoc: section headers are two-space-indented
/// capitalised lines, lane rows are four-space-indented `name  description`.
/// Only rows under CLOUD sections whose name is also a defined function count.
func parseLanes(configPath: String = CLAUDE_CONFIG_PATH) -> [LaneEntry] {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
    let lines = text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.hasPrefix("lcp-help()") }) else { return [] }

    var definedFunctions = Set<String>()
    let fnRegex = try! NSRegularExpression(pattern: #"^([a-z][a-z0-9-]*)\(\)"#)
    for l in lines {
        let r = NSRange(l.startIndex..<l.endIndex, in: l)
        if let m = fnRegex.firstMatch(in: l, range: r), let nr = Range(m.range(at: 1), in: l) {
            definedFunctions.insert(String(l[nr]))
        }
    }

    var lanes: [LaneEntry] = []
    var group = ""
    let rowRegex = try! NSRegularExpression(pattern: #"^    ([a-z][a-z0-9-]*)(?: \[[^\]]*\])?\s{2,}(.+)$"#)
    for l in lines[(start + 1)...] {
        if l.hasPrefix("EOF") { break }
        if l.hasPrefix("  ") && !l.hasPrefix("    ") {
            group = l.trimmingCharacters(in: .whitespaces)
            continue
        }
        guard group.hasPrefix("CLOUD") else { continue }
        let r = NSRange(l.startIndex..<l.endIndex, in: l)
        guard let m = rowRegex.firstMatch(in: l, range: r),
              let nameR = Range(m.range(at: 1), in: l),
              let descR = Range(m.range(at: 2), in: l) else { continue }
        let name = String(l[nameR])
        guard definedFunctions.contains(name), !laneExclusions.contains(name) else { continue }
        lanes.append(LaneEntry(name: name, description: String(l[descR]).trimmingCharacters(in: .whitespaces), group: group))
    }
    return lanes
}

func loadLaneStatus(path: String = LANE_STATUS_PATH) -> LaneStatusDoc? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(LaneStatusDoc.self, from: data)
}

/// Opens a new terminal window running the lane inside an interactive zsh (so
/// ~/.zshrc sources the config and the keychain loader runs). Ghostty by default;
/// anything else falls back to Terminal.app via AppleScript.
func launchLane(_ lane: String) {
    let command = "\(lane); exec zsh -i"
    if TERMINAL_APP.lowercased() == "ghostty",
       NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", "Ghostty", "--args", "-e", "zsh", "-ic", command]
        try? p.run()
        return
    }
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let script = "tell application \"Terminal\"\nactivate\ndo script \"zsh -ic \\\"\(escaped)\\\"\"\nend tell"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}

/// Runs the probe script (writes the JSON cache). Completion on the main thread.
func runLaneProbe(completion: @escaping (Bool) -> Void) {
    guard FileManager.default.isReadableFile(atPath: LANE_PROBE_PATH) else {
        DispatchQueue.main.async { completion(false) }
        return
    }
    DispatchQueue.global(qos: .utility).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [LANE_PROBE_PATH, "--quiet"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var ok = false
        do {
            try p.run()
            p.waitUntilExit()
            ok = p.terminationStatus == 0
        } catch {}
        DispatchQueue.main.async { completion(ok) }
    }
}

func relativeAge(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    guard let d = f.date(from: iso) else { return iso }
    let s = Int(Date().timeIntervalSince(d))
    if s < 90 { return "just now" }
    if s < 5400 { return "\(s / 60) min ago" }
    if s < 172800 { return "\(s / 3600) h ago" }
    return "\(s / 86400) d ago"
}
