import AppKit
import Darwin
import Foundation
import Sparkle

// Every path below can be overridden via env var (e.g. in the launchd plist or
// a wrapper script) so this isn't tied to one machine's folder layout.
func env(_ key: String, default def: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? def
}

let LCP_MODELS_DIR = env("LOCALMODELSBAR_LCP_DIR", default: NSHomeDirectory() + "/llama-cpp-setup/models")
let LCP_PIDFILE = env("LOCALMODELSBAR_LCP_PIDFILE", default: NSHomeDirectory() + "/.cache/lcp/llama-server.pid")
let HF_CACHE_DIR = env("LOCALMODELSBAR_HF_CACHE_DIR", default: NSHomeDirectory() + "/.cache/huggingface/hub")
let OLLAMA_HOST = env("LOCALMODELSBAR_OLLAMA_HOST", default: "http://127.0.0.1:11434")
let OLLAMA_TAGS_URL = URL(string: OLLAMA_HOST + "/api/tags")!

let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useGB, .useMB]
    f.countStyle = .file
    return f
}()

struct ModelEntry {
    let name: String
    let sizeBytes: Int64
    let path: String?      // for "reveal in Finder"
    let badge: String?     // e.g. "running", "cloud"
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

func lcpServerRunning() -> Bool {
    guard let pidStr = try? String(contentsOfFile: LCP_PIDFILE, encoding: .utf8),
          let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return false
    }
    return isProcessAlive(pid)
}

let shardRegex = try! NSRegularExpression(pattern: #"^(.+)-(\d{5})-of-(\d{5})\.gguf$"#)

func lcpModels() -> [ModelEntry] {
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
        entries.append(ModelEntry(name: f, sizeBytes: fileSize(path), path: path, badge: nil))
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
            badge: nil
        ))
    }

    return entries.sorted { $0.name < $1.name }
}

// MARK: - Ollama

func ollamaModels() -> [ModelEntry] {
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
            result.append(ModelEntry(name: name, sizeBytes: isCloud ? 0 : size, path: nil, badge: isCloud ? "cloud" : nil))
        }
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 2.0)

    if !reached {
        return [ModelEntry(name: "Ollama not reachable on :11434", sizeBytes: 0, path: nil, badge: nil)]
    }
    return result.sorted { $0.name < $1.name }
}

// MARK: - Hugging Face cache

func hfCacheModels() -> [ModelEntry] {
    guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: HF_CACHE_DIR) else {
        return []
    }
    let repoDirs = dirs.filter { $0.hasPrefix("models--") }
    return repoDirs.map { d in
        let path = HF_CACHE_DIR + "/" + d
        let name = d.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "--", with: "/")
        return ModelEntry(name: name, sizeBytes: directorySize(path), path: path, badge: nil)
    }.sorted { $0.name < $1.name }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    // Sparkle: startingUpdater true polls on launch + every 24h per Info.plist's
    // SUScheduledCheckInterval. updaterDelegate/userDriverDelegate nil = defaults.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            // Bundle.main finds Contents/Resources/icon.svg in the packaged .app
            // (bundle.sh copies it there). Bundle.module is the SPM-resource-bundle
            // fallback for `swift run` during development, where there's no
            // Contents/Resources — only used when Bundle.main comes up empty.
            let icon = (Bundle.main.url(forResource: "icon", withExtension: "svg")
                ?? Bundle.module.url(forResource: "icon", withExtension: "svg"))
                .flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(systemSymbolName: "cpu", accessibilityDescription: "Local Models")
            icon?.isTemplate = false  // keep the gradient — don't let the menu bar flatten it to monochrome
            icon?.size = NSSize(width: 18, height: 18)
            button.image = icon
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let running = lcpServerRunning()
        let lcp = lcpModels()
        menu.addItem(sectionHeader("Local (lcp)", models: lcp))
        menu.addItem(infoItem(running ? "●  llama-server running · port 8776" : "○  llama-server stopped"))
        appendModels(lcp, to: menu, emptyText: "No GGUF models downloaded — try \"hf\" or \"lcp --pull\"")

        menu.addItem(.separator())
        let ollama = ollamaModels()
        menu.addItem(sectionHeader("Ollama", models: ollama))
        appendModels(ollama, to: menu, emptyText: "No Ollama models")

        menu.addItem(.separator())
        let hf = hfCacheModels()
        menu.addItem(sectionHeader("Hugging Face cache", models: hf))
        appendModels(hf, to: menu, emptyText: "Cache empty — this setup downloads straight into project folders")

        menu.addItem(.separator())
        let checkForUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = self
        checkForUpdates.isEnabled = updaterController.updater.canCheckForUpdates
        menu.addItem(checkForUpdates)

        let quit = NSMenuItem(title: "Quit SakshiBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func checkForUpdates(_ sender: NSMenuItem) {
        updaterController.checkForUpdates(nil)
    }

    func appendModels(_ models: [ModelEntry], to menu: NSMenu, emptyText: String) {
        if models.isEmpty {
            menu.addItem(infoItem("    \(emptyText)"))
            return
        }
        for m in models {
            let sizeStr = m.sizeBytes > 0 ? byteFormatter.string(fromByteCount: m.sizeBytes) : ""
            var title = "    \(m.name)"
            if !sizeStr.isEmpty { title += "  ·  \(sizeStr)" }
            if m.badge != nil { title += "  \u{2601}\u{FE0F}" }  // cloud emoji marker
            let action = m.path != nil ? #selector(revealInFinder(_:)) : #selector(copyName(_:))
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = m.path ?? m.name
            item.toolTip = m.path ?? "Click to copy \"\(m.name)\""
            menu.addItem(item)
        }
    }

    func sectionHeader(_ text: String, models: [ModelEntry]) -> NSMenuItem {
        var label = text
        if !models.isEmpty {
            let total = models.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let countStr = "\(models.count) model\(models.count == 1 ? "" : "s")"
            label += total > 0 ? "  —  \(countStr), \(byteFormatter.string(fromByteCount: total))" : "  —  \(countStr)"
        }
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: label,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        item.isEnabled = false
        return item
    }

    func infoItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func revealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    @objc func copyName(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
