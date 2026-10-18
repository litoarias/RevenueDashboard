import Foundation

public enum ASCError: Error {
    case notYetAvailable          // 404: Apple aún no publica ese día (no es un error real)
    case http(Int, String)
}

public struct ASCClient: Sendable {
    let credentials: ASCCredentials
    let session: URLSession

    public init(credentials: ASCCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// Informe diario de ventas (SALES/SUMMARY) para un día en UTC-agnóstico (yyyy-MM-dd).
    public func dailySales(on day: String) async throws -> [SalesRow] {
        var comps = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/salesReports")!
        comps.queryItems = [
            .init(name: "filter[frequency]", value: "DAILY"),
            .init(name: "filter[reportType]", value: "SALES"),
            .init(name: "filter[reportSubType]", value: "SUMMARY"),
            .init(name: "filter[vendorNumber]", value: credentials.vendorNumber),
            .init(name: "filter[reportDate]", value: day),
            .init(name: "filter[version]", value: "1_1"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(try ASCToken.make(credentials))", forHTTPHeaderField: "Authorization")
        req.setValue("application/a-gzip", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            let raw = (try? data.gunzipped()) ?? data
            return SalesReportParser.parse(String(decoding: raw, as: UTF8.self))
        case 404: throw ASCError.notYetAvailable
        default: throw ASCError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }
}

extension ASCClient {
    /// SKU de la app → nombre (el `Parent Identifier` de los informes de ventas es el SKU de la app).
    public func appNames() async throws -> [String: String] {
        var req = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/apps?limit=200&fields%5Bapps%5D=name,sku")!)
        req.setValue("Bearer \(try ASCToken.make(credentials))", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ASCError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        struct R: Decodable { struct A: Decodable { struct At: Decodable { let name: String; let sku: String }; let attributes: At }; let data: [A] }
        return Dictionary(try JSONDecoder().decode(R.self, from: data).data.map { ($0.attributes.sku, $0.attributes.name) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Ventas diarias del rango (4 peticiones en paralelo). Los días ya cerrados se sirven de la caché.
    public func sales(from: Date, to: Date, cache: SalesCache? = nil, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> (rows: [SalesRow], errors: [String], through: Date?) {
        var days: [Date] = []
        var d = from
        while d <= to { days.append(d); d = d.addingTimeInterval(86400) }
        var rows: [SalesRow] = [], errors: [String] = []
        var through: Date?
        var done = 0
        let settled = Date().addingTimeInterval(-5 * 86400)

        for chunk in stride(from: 0, to: days.count, by: 8).map({ Array(days[$0..<min($0 + 8, days.count)]) }) {
            await withTaskGroup(of: (String, Result<[SalesRow], Error>?).self) { group in
                for day in chunk {
                    let key = ECBRates.dayKey(day)
                    group.addTask {
                        if day < settled, let hit = await cache?.rows(for: key) { return (key, .success(hit)) }
                        do {
                            let r = try await self.dailySales(on: key)
                            await cache?.store(r, for: key)
                            return (key, .success(r))
                        } catch ASCError.notYetAvailable { return (key, nil) }
                        catch { return (key, .failure(error)) }
                    }
                }
                for await (key, result) in group {
                    done += 1; progress?(done, days.count)
                    switch result {
                    case .success(let r):
                        rows += r
                        if let d = chunk.first(where: { ECBRates.dayKey($0) == key }), d > (through ?? .distantPast) { through = d }
                    case .failure(let e): errors.append("\(key): \(e)")
                    case nil: break
                    }
                }
            }
        }
        await cache?.save()
        return (rows, errors, through)
    }
}

/// Caché en disco de los informes diarios de Apple (clave: yyyy-MM-dd).
public actor SalesCache {
    private var days: [String: [SalesRow]]
    private let url: URL

    public init(url: URL) {
        self.url = url
        self.days = (try? JSONDecoder().decode([String: [SalesRow]].self, from: Data(contentsOf: url))) ?? [:]
    }

    func rows(for key: String) -> [SalesRow]? { days[key] }
    func store(_ rows: [SalesRow], for key: String) { days[key] = rows }
    func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(days).write(to: url)
    }
}
