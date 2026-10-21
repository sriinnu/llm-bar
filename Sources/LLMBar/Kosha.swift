import Foundation

// Optional pricing from kosha (github.com/sriinnu/kosha-discovery): its registry is a
// plain JSON file, so we read it directly — no process, no MCP. Missing file = no prices.
struct KoshaPrice {
    let provider: String
    let inputPerMillion: Double
    let outputPerMillion: Double
    let contextWindow: Int?
    let exactProvider: Bool
}

final class KoshaRegistry {
    static let shared = KoshaRegistry()
    private var byModel: [String: [KoshaPrice]] = [:]     // lowercased modelId -> rows
    private var loadedMtime: Date?
    private var loadedPath = ""
    private(set) var modelCount = 0

    var summary: String {
        reload()
        guard loadedMtime != nil else { return "No registry at \(AppSettings.shared.string(AppSettings.koshaRegistry)) — install kosha and run `kosha discover`." }
        return "\(modelCount) models loaded from kosha."
    }

    private func reload() {
        let path = AppSettings.shared.string(AppSettings.koshaRegistry)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
        if path == loadedPath && mtime == loadedMtime { return }
        loadedPath = path; loadedMtime = mtime; byModel = [:]; modelCount = 0
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return }
        for m in models {
            guard let id = m["modelId"] as? String, let prov = m["providerId"] as? String,
                  let pricing = m["pricing"] as? [String: Any],
                  let inp = (pricing["inputPerMillion"] as? NSNumber)?.doubleValue,
                  let out = (pricing["outputPerMillion"] as? NSNumber)?.doubleValue else { continue }
            let ctx = (m["contextWindow"] as? NSNumber)?.intValue
            byModel[id.lowercased(), default: []].append(KoshaPrice(provider: prov, inputPerMillion: inp, outputPerMillion: out, contextWindow: ctx, exactProvider: false))
        }
        modelCount = models.count
    }

    /// Price row for a model. Prefers the lane's kosha provider; otherwise the first row, flagged.
    func price(model: String, provider: String?) -> KoshaPrice? {
        reload()
        guard let rows = byModel[model.lowercased()], !rows.isEmpty else { return nil }
        if let p = provider, !p.isEmpty, let r = rows.first(where: { $0.provider == p }) {
            return KoshaPrice(provider: r.provider, inputPerMillion: r.inputPerMillion, outputPerMillion: r.outputPerMillion, contextWindow: r.contextWindow, exactProvider: true)
        }
        return rows[0]
    }
}

func formatPrice(_ p: KoshaPrice) -> String {
    func f(_ x: Double) -> String { x < 0.01 ? String(format: "%.3f", x) : String(format: "%.2f", x) }
    var s = "$\(f(p.inputPerMillion)) / $\(f(p.outputPerMillion)) per M"
    if let c = p.contextWindow, c > 0 { s += c >= 1_000_000 ? " · \(c / 1_000_000)M ctx" : " · \(c / 1000)k ctx" }
    if !p.exactProvider { s += " (\(p.provider) price)" }
    return s
}
