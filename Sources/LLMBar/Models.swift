import Foundation

// Every path below can be overridden via env var so this isn't tied to one
// machine's folder layout — LLM Bar is a public app, not everyone has
// this exact llama-cpp-setup convention.
func env(_ key: String, default def: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? def
}

let LCP_MODELS_DIR = env("LLMBAR_LCP_DIR", default: NSHomeDirectory() + "/llama-cpp-setup/models")
let LCP_PIDFILE = env("LLMBAR_LCP_PIDFILE", default: NSHomeDirectory() + "/.cache/lcp/llama-server.pid")
let HF_CACHE_DIR = env("LLMBAR_HF_CACHE_DIR", default: NSHomeDirectory() + "/.cache/huggingface/hub")
let OLLAMA_HOST = env("LLMBAR_OLLAMA_HOST", default: "http://127.0.0.1:11434")
let OLLAMA_TAGS_URL = URL(string: OLLAMA_HOST + "/api/tags")!

let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useGB, .useMB]
    f.countStyle = .file
    return f
}()

struct ModelEntry: Identifiable {
    var id: String { name }
    let name: String
    let sizeBytes: Int64
    let path: String?      // for "reveal in Finder" / server start target
    let isCloud: Bool
}

func fileSize(_ path: String) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
}

func directorySize(_ path: String) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
    var total: Int64 = 0
    for case let file as String in enumerator {
        total += fileSize(path + "/" + file)
    }
    return total
}

func isProcessAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

// MARK: - lcp (llama.cpp local models)

func lcpServerPid() -> Int32? {
    guard let pidStr = try? String(contentsOfFile: LCP_PIDFILE, encoding: .utf8),
          let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
          isProcessAlive(pid) else {
        return nil
    }
    return pid
}

func lcpServerRunning() -> Bool {
    lcpServerPid() != nil
}

let shardRegex = try! NSRegularExpression(pattern: #"^(.+)-(\d{5})-of-(\d{5})\.gguf$"#)

func fetchLcpModels() -> [ModelEntry] {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: LCP_MODELS_DIR) else {
        return []
    }
    let ggufFiles = files.filter { $0.hasSuffix(".gguf") }.sorted()

    var shardGroups: [String: [String]] = [:]
    var singles: [String] = []

    for f in ggufFiles {
        let range = NSRange(f.startIndex..<f.endIndex, in: f)
        if let m = shardRegex.firstMatch(in: f, range: range),
           let prefixRange = Range(m.range(at: 1), in: f),
           let totalRange = Range(m.range(at: 3), in: f) {
            let key = "\(f[prefixRange])|\(f[totalRange])"
            shardGroups[key, default: []].append(f)
        } else {
            singles.append(f)
        }
    }

    var entries: [ModelEntry] = []

    for f in singles {
        let path = LCP_MODELS_DIR + "/" + f
        entries.append(ModelEntry(name: f, sizeBytes: fileSize(path), path: path, isCloud: false))
    }

    for (key, shardFiles) in shardGroups {
        let prefix = String(key.split(separator: "|")[0])
        let total = shardFiles.count
        let size = shardFiles.reduce(Int64(0)) { $0 + fileSize(LCP_MODELS_DIR + "/" + $1) }
        let sortedShards = shardFiles.sorted()
        let firstShardPath = LCP_MODELS_DIR + "/" + (sortedShards.first ?? "")
        entries.append(ModelEntry(
            name: "\(prefix).gguf (\(total) shards)",
            sizeBytes: size,
            path: firstShardPath,
            isCloud: false
        ))
    }

    return entries.sorted { $0.name < $1.name }
}

// MARK: - Ollama

func fetchOllamaModels() -> [ModelEntry] {
    var request = URLRequest(url: OLLAMA_TAGS_URL)
    request.timeoutInterval = 1.5

    let semaphore = DispatchSemaphore(value: 0)
    var result: [ModelEntry] = []
    var reached = false

    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
        defer { semaphore.signal() }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return
        }
        reached = true
        for m in models {
            guard let name = m["name"] as? String else { continue }
            let isCloud = m["remote_host"] != nil
            let size = (m["size"] as? NSNumber)?.int64Value ?? 0
            result.append(ModelEntry(name: name, sizeBytes: isCloud ? 0 : size, path: nil, isCloud: isCloud))
        }
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 2.0)

    if !reached { return [] }
    return result.sorted { $0.name < $1.name }
}

func ollamaReachable() -> Bool {
    var request = URLRequest(url: OLLAMA_TAGS_URL)
    request.timeoutInterval = 1.0
    let semaphore = DispatchSemaphore(value: 0)
    var ok = false
    let task = URLSession.shared.dataTask(with: request) { _, response, _ in
        ok = (response as? HTTPURLResponse)?.statusCode == 200
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 1.5)
    return ok
}

// MARK: - Hugging Face cache

func fetchHfCacheModels() -> [ModelEntry] {
    guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: HF_CACHE_DIR) else {
        return []
    }
    let repoDirs = dirs.filter { $0.hasPrefix("models--") }
    return repoDirs.map { d in
        let path = HF_CACHE_DIR + "/" + d
        let name = d.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "--", with: "/")
        return ModelEntry(name: name, sizeBytes: directorySize(path), path: path, isCloud: false)
    }.sorted { $0.name < $1.name }
}
