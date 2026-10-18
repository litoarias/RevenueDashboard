import Foundation

/// Tipos de cambio diarios del BCE (histórico de 90 días). Valores: unidades de divisa por 1 EUR.
public struct ECBRates: Sendable {
    let byDay: [String: [String: Decimal]]
    let sortedDays: [String]
    /// Divisas que el BCE no publica (CLP, AED…): último cambio disponible de otra fuente.
    let fallback: [String: Decimal]

    public init(byDay: [String: [String: Decimal]], fallback: [String: Decimal] = [:]) {
        self.byDay = byDay
        self.sortedDays = byDay.keys.sorted()
        self.fallback = fallback
    }

    public static let fallbackURL = URL(string: "https://open.er-api.com/v6/latest/EUR")!

    public static let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml")!

    public static let histURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml")!

    /// Hasta ~85 días basta el histórico de 90 días. Más allá se usa el histórico completo, recortado y cacheado 12 h.
    public static func fetch(days: Int = 90, cacheDirectory: URL? = nil, session: URLSession = .shared) async throws -> ECBRates {
        let extra = (try? await fetchFallback(session: session)) ?? [:]
        if days <= 85 {
            let (data, _) = try await session.data(from: url)
            return ECBRates(byDay: try parse(data).byDay, fallback: extra)
        }
        let file = cacheDirectory?.appending(path: "ecb-hist.json")
        if let file, let m = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < 12 * 3600, let d = try? Data(contentsOf: file),
           let byDay = try? JSONDecoder().decode([String: [String: Decimal]].self, from: d) {
            return ECBRates(byDay: byDay, fallback: extra)
        }
        let (data, _) = try await session.data(from: histURL)
        let parsed = try parse(data, since: dayKey(Date().addingTimeInterval(-420 * 86400)))
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(parsed.byDay).write(to: file)
        }
        return ECBRates(byDay: parsed.byDay, fallback: extra)
    }

    public static func parse(_ data: Data, since: String = "") throws -> ECBRates {
        let delegate = Parser(since: since)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? URLError(.cannotParseResponse) }
        return ECBRates(byDay: delegate.days)
    }

    static func fetchFallback(session: URLSession) async throws -> [String: Decimal] {
        let (data, _) = try await session.data(from: fallbackURL)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let r = o["rates"] as? [String: Any] else { return [:] }
        return r.compactMapValues { ($0 as? NSNumber).map { Decimal($0.doubleValue) } }
    }

    public func canConvert(_ currency: String) -> Bool {
        currency == "EUR" || fallback[currency] != nil || byDay.values.contains { $0[currency] != nil }
    }

    public static func dayKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Importe convertido a EUR con el cambio del día (o el último anterior disponible, o el más antiguo).
    public func toEUR(_ amount: Decimal, currency: String, on date: Date) -> Decimal? {
        if currency == "EUR" { return amount }
        let key = Self.dayKey(date)
        let day = sortedDays.last(where: { $0 <= key }) ?? sortedDays.first
        guard let rate = day.flatMap({ byDay[$0]?[currency] }) ?? fallback[currency], rate != 0 else { return nil }
        return amount / rate
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var days: [String: [String: Decimal]] = [:]
        var current: String?
        let since: String
        init(since: String) { self.since = since }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            guard name == "Cube" else { return }
            if let t = a["time"] { if t >= since { current = t; days[t] = [:] } else { current = nil } }
            else if let c = a["currency"], let r = a["rate"], let day = current, let d = Decimal(string: r, locale: Locale(identifier: "en_US_POSIX")) {
                days[day]?[c] = d
            }
        }
    }
}
