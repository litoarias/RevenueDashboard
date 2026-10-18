import Foundation
import RevenueKit

// Herramienta de desarrollo: reutiliza la clave del MCP de App Store Connect y no imprime secretos.
// Uso: ASC_VENDOR_NUMBER=12345678 swift run revenue-probe [días]
struct Company: Decodable { let key_id: String, issuer_id: String, key_path: String }
struct Companies: Decodable { let companies: [Company] }

let home = FileManager.default.homeDirectoryForCurrentUser
let cfg = try JSONDecoder().decode(Companies.self, from: Data(contentsOf: home.appending(path: ".config/asc-mcp/companies.json"))).companies[0]
let pem = try String(contentsOfFile: (cfg.key_path as NSString).expandingTildeInPath, encoding: .utf8)
let vendor = ProcessInfo.processInfo.environment["ASC_VENDOR_NUMBER"] ?? ""
let client = ASCClient(credentials: .init(issuerID: cfg.issuer_id, keyID: cfg.key_id, privateKeyPEM: pem, vendorNumber: vendor))

let fmt = DateFormatter()
fmt.dateFormat = "yyyy-MM-dd"
fmt.timeZone = TimeZone(identifier: "UTC")
let days = Int(CommandLine.arguments.dropFirst().first ?? "7") ?? 7

let to = Date().addingTimeInterval(-86400)
let from = to.addingTimeInterval(-Double(days - 1) * 86400)
let rates = try await ECBRates.fetch(days: days)
let names = (try? await client.appNames()) ?? [:]
let (rows, errors, _) = await client.sales(from: from, to: to)
errors.forEach { print("error:", $0) }
let entries = RevenueAggregator.combine(sales: rows, appNames: names, ads: [], rates: rates)
print("\(rows.count) filas de Apple, \(names.count) apps, \(entries.count) entradas")
for s in RevenueSource.allCases {
    let t = entries.filter { $0.source == s }.reduce(Decimal(0)) { $0 + $1.eur }
    print(s.label.padding(toLength: 16, withPad: " ", startingAt: 0), "\(t) EUR")
}
Dictionary(grouping: entries, by: \.app).mapValues { $0.reduce(Decimal(0)) { $0 + $1.eur } }
    .sorted { $0.value > $1.value }.forEach { print(" -", $0.key, $0.value) }

print("\n--- desglose por app/producto/divisa (proceeds originales) ---")
struct K: Hashable { let app: String; let sku: String; let cur: String; let type: String }
var d: [K: (Decimal, Int)] = [:]
for r in rows where r.proceeds != 0 {
    let app = names[r.parentID] ?? r.parentID
    d[K(app: app, sku: r.sku, cur: r.proceedsCurrency, type: r.productType), default: (0, 0)].0 += r.proceeds
    d[K(app: app, sku: r.sku, cur: r.proceedsCurrency, type: r.productType), default: (0, 0)].1 += r.units
}
for (k, v) in d.sorted(by: { $0.key.app < $1.key.app }) { print(k.app, "|", k.sku, k.type, k.cur, v.0, "uds:", v.1) }
print("días con datos:", Set(rows.map { ECBRates.dayKey($0.date) }).sorted().last ?? "-")
