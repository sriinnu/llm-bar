import AppKit
import Darwin
import Foundation

// Self-contained llama-server start/stop, deliberately NOT shelling out to the
// `lcp` shell function — that function also launches an entire Claude Code
// session tied to the server and blocks waiting for it to exit, which is the
// wrong shape for a GUI start/stop button, and LLM Bar needs to work for
// people who don't have that dotfile at all. This mirrors the same flags,
// pidfile, and port lcp itself uses, so `lcp --status`/`--stop` from a
// terminal still recognizes a server started from the app, and vice versa.

var LCP_SERVER_PATH: String { AppSettings.shared.string(AppSettings.lcpServer) }
let LCP_PORT = env("LLMBAR_LCP_PORT", default: "8776")
let LCP_CTX_SIZE = env("LLMBAR_LCP_CTX_SIZE", default: "32768")
let LCP_GPU_LAYERS = env("LLMBAR_LCP_GPU_LAYERS", default: "99")
let LCP_BATCH_SIZE = env("LLMBAR_LCP_BATCH_SIZE", default: "4096")
let LCP_UBATCH_SIZE = env("LLMBAR_LCP_UBATCH_SIZE", default: "1024")
let LCP_LOG_PATH = NSHomeDirectory() + "/.cache/lcp/llama-server.log"

enum LcpStartResult {
    case started
    case alreadyRunning
    case binaryMissing
    case insufficientMemory(availableGB: Double, neededGB: Double)
    case failed(String)
}

/// Reclaimable memory right now: free + inactive + speculative pages, the
/// same figure `vm_stat` reports. Deliberately conservative — this is what
/// the kernel can actually hand a new process without swapping, not total
/// installed RAM.
func availableMemoryBytes() -> Int64 {
    var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    var stats = vm_statistics64_data_t()
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }

    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)

    let reclaimablePages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
    return Int64(reclaimablePages) * Int64(pageSize)
}

// A GGUF's on-disk size is roughly what it costs resident in RAM once
// loaded (quantized weights dominate), but context/KV cache adds overhead
// on top — 1.15x is a conservative pad, not a precise model.
private let MEMORY_SAFETY_FACTOR = 1.15

func startLcpServer(modelPath: String) -> LcpStartResult {
    if lcpServerRunning() { return .alreadyRunning }

    guard FileManager.default.isExecutableFile(atPath: LCP_SERVER_PATH) else {
        return .binaryMissing
    }

    let modelBytes = fileSize(modelPath)
    let available = availableMemoryBytes()
    let needed = Int64(Double(modelBytes) * MEMORY_SAFETY_FACTOR)
    if modelBytes > 0 && available > 0 && available < needed {
        return .insufficientMemory(
            availableGB: Double(available) / 1e9,
            neededGB: Double(needed) / 1e9
        )
    }

    let pidDir = (LCP_PIDFILE as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: pidDir, withIntermediateDirectories: true)

    let perfCores = ProcessInfo.processInfo.activeProcessorCount
    let threads = max(1, perfCores - 2)  // leave headroom, matches lcp's perf-core heuristic loosely

    let process = Process()
    process.executableURL = URL(fileURLWithPath: LCP_SERVER_PATH)
    process.arguments = [
        "--model", modelPath,
        "--port", LCP_PORT,
        "--ctx-size", LCP_CTX_SIZE,
        "--n-gpu-layers", LCP_GPU_LAYERS,
        "--threads", "\(threads)",
        "--batch-size", LCP_BATCH_SIZE,
        "--ubatch-size", LCP_UBATCH_SIZE,
        "--flash-attn", "on",
        "--cont-batching",
        // Deliberately NOT --mlock: it pins the model non-swappable, which
        // is fine run deliberately from a terminal but caused a real crash
        // here when stacked on top of Ollama's own loaded model — a GUI
        // button can be clicked without that same awareness of what else
        // is running. Let the kernel degrade gracefully instead.
        "--cache-type-k", "q8_0",
        "--cache-type-v", "q8_0",
        "--log-disable",
    ]

    FileManager.default.createFile(atPath: LCP_LOG_PATH, contents: nil)
    let logHandle = FileHandle(forWritingAtPath: LCP_LOG_PATH)
    process.standardOutput = logHandle
    process.standardError = logHandle

    do {
        try process.run()
    } catch {
        return .failed(error.localizedDescription)
    }

    try? "\(process.processIdentifier)".write(toFile: LCP_PIDFILE, atomically: true, encoding: .utf8)
    return .started
}

func stopLcpServer() {
    guard let pid = lcpServerPid() else { return }
    kill(pid, SIGTERM)
    try? FileManager.default.removeItem(atPath: LCP_PIDFILE)
}

// MARK: - Ollama (its own menu-bar app owns process supervision; we just
// launch/quit the app rather than fighting it by managing `ollama serve`
// directly)

let OLLAMA_BUNDLE_ID = "com.electron.ollama"

func ollamaAppRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == OLLAMA_BUNDLE_ID }
}

func startOllamaApp() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OLLAMA_BUNDLE_ID) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

func stopOllamaApp() {
    for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == OLLAMA_BUNDLE_ID {
        app.terminate()
    }
}
