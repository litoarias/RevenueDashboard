import Foundation

public enum AdMobError: Error { case noAccount, http(Int, String), badResponse }

public struct AdMobClient: Sendable {
    let accessToken: @Sendable () async throws -> String
    let session: URLSession

    public init(accessToken: @escaping @Sendable () async throws -> String, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.session = session
    }

    /// Nombres de cuenta tipo `accounts/pub-1234567890123456`.
    public func accounts() async throws -> [String] {
        let data = try await send(URLRequest(url: URL(string: "https://admob.googleapis.com/v1/accounts")!))
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AdMobError.badResponse }
        return (o["account"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// Ingresos estimados por día y app, ya en EUR (AdMob convierte con `localizationSettings`).
    public func earnings(account: String, from: Date, to: Date) async throws -> [AdMobRow] {
        func ymd(_ d: Date) -> [String: Int] {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return ["year": c.year!, "month": c.month!, "day": c.day!]
        }
        let body: [String: Any] = ["reportSpec": [
            "dateRange": ["startDate": ymd(from), "endDate": ymd(to)],
            "dimensions": ["DATE", "APP"],
            "metrics": ["ESTIMATED_EARNINGS"],
            "localizationSettings": ["currencyCode": "EUR"],
        ]]
        var req = URLRequest(url: URL(string: "https://admob.googleapis.com/v1/\(account)/networkReport:generate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try Self.parse(try await send(req))
    }

    /// La respuesta es un array JSON en streaming: cabecera, filas `{row}` y pie.
    public static func parse(_ data: Data) throws -> [AdMobRow] {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw AdMobError.badResponse }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return arr.compactMap { item in
            guard let row = item["row"] as? [String: Any],
                  let dims = row["dimensionValues"] as? [String: [String: Any]],
                  let metrics = row["metricValues"] as? [String: [String: Any]],
                  let day = dims["DATE"]?["value"] as? String, let date = fmt.date(from: day),
                  let app = dims["APP"], let appID = app["value"] as? String,
                  let micros = metrics["ESTIMATED_EARNINGS"]?["microsValue"] as? String,
                  let m = Decimal(string: micros) else { return nil }
            return AdMobRow(date: date, appID: appID, appName: (app["displayLabel"] as? String) ?? appID, eur: m / 1_000_000)
        }
    }

    private func send(_ r: URLRequest) async throws -> Data {
        var req = r
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AdMobError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        return data
    }
}
