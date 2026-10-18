import Foundation

public struct AnalyticsProperty: Sendable, Hashable, Identifiable {
    public let id: String          // properties/123456
    public let name: String
    public let account: String
    public init(id: String, name: String, account: String) { self.id = id; self.name = name; self.account = account }
}

public struct UsageDay: Sendable, Equatable {
    public let date: Date
    public let activeUsers: Int
    public let newUsers: Int
    public let sessions: Int
    public let events: Int
    public init(date: Date, activeUsers: Int, newUsers: Int, sessions: Int, events: Int) {
        self.date = date; self.activeUsers = activeUsers; self.newUsers = newUsers; self.sessions = sessions; self.events = events
    }
}

public struct PropertyUsage: Sendable, Identifiable {
    public var id: String { property.id }
    public let property: AnalyticsProperty
    public let days: [UsageDay]
    /// Totales del periodo (usuarios únicos, no la suma de los diarios).
    public let activeUsers: Int
    public let newUsers: Int
    public let sessions: Int
    public let events: Int
    public init(property: AnalyticsProperty, days: [UsageDay], activeUsers: Int, newUsers: Int, sessions: Int, events: Int) {
        self.property = property; self.days = days; self.activeUsers = activeUsers; self.newUsers = newUsers; self.sessions = sessions; self.events = events
    }
}

public enum AnalyticsError: Error { case http(Int, String), badResponse }

/// Firebase Analytics = GA4: se listan todas las propiedades de golpe (Admin API) y se consulta cada una (Data API).
public struct AnalyticsClient: Sendable {
    let accessToken: @Sendable () async throws -> String
    let session: URLSession

    public init(accessToken: @escaping @Sendable () async throws -> String, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.session = session
    }

    public func properties() async throws -> [AnalyticsProperty] {
        var out: [AnalyticsProperty] = [], token: String?
        repeat {
            var c = URLComponents(string: "https://analyticsadmin.googleapis.com/v1beta/accountSummaries")!
            c.queryItems = [.init(name: "pageSize", value: "200")] + (token.map { [.init(name: "pageToken", value: $0)] } ?? [])
            let data = try await send(URLRequest(url: c.url!))
            let (props, next) = try Self.parseProperties(data)
            out += props; token = next
        } while token != nil
        return out
    }

    public func usage(for property: AnalyticsProperty, days: Int) async throws -> PropertyUsage {
        let range: [String: Any] = ["startDate": "\(days)daysAgo", "endDate": "yesterday"]
        let metrics = ["activeUsers", "newUsers", "sessions", "eventCount"].map { ["name": $0] }
        let body: [String: Any] = ["requests": [
            ["dateRanges": [range], "dimensions": [["name": "date"]], "metrics": metrics, "limit": 1000],
            ["dateRanges": [range], "metrics": metrics],
        ]]
        var req = URLRequest(url: URL(string: "https://analyticsdata.googleapis.com/v1beta/\(property.id):batchRunReports")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try Self.parseUsage(try await send(req), property: property)
    }

    // MARK: Parsers (públicos para tests)

    public static func parseProperties(_ data: Data) throws -> ([AnalyticsProperty], next: String?) {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AnalyticsError.badResponse }
        var out: [AnalyticsProperty] = []
        for acc in o["accountSummaries"] as? [[String: Any]] ?? [] {
            let accName = acc["displayName"] as? String ?? ""
            for p in acc["propertySummaries"] as? [[String: Any]] ?? [] {
                if let id = p["property"] as? String { out.append(.init(id: id, name: p["displayName"] as? String ?? id, account: accName)) }
            }
        }
        return (out, o["nextPageToken"] as? String)
    }

    public static func parseUsage(_ data: Data, property: AnalyticsProperty) throws -> PropertyUsage {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let reports = o["reports"] as? [[String: Any]], reports.count == 2
        else { throw AnalyticsError.badResponse }
        func metrics(_ row: [String: Any]) -> [Int] {
            (row["metricValues"] as? [[String: Any]] ?? []).map { Int($0["value"] as? String ?? "") ?? 0 }
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"; fmt.timeZone = TimeZone(identifier: "UTC"); fmt.locale = Locale(identifier: "en_US_POSIX")
        let days: [UsageDay] = (reports[0]["rows"] as? [[String: Any]] ?? []).compactMap { row in
            guard let v = (row["dimensionValues"] as? [[String: Any]])?.first?["value"] as? String, let d = fmt.date(from: v) else { return nil }
            let m = metrics(row) + [0, 0, 0, 0]
            return UsageDay(date: d, activeUsers: m[0], newUsers: m[1], sessions: m[2], events: m[3])
        }.sorted { $0.date < $1.date }
        let t = ((reports[1]["rows"] as? [[String: Any]])?.first.map(metrics) ?? []) + [0, 0, 0, 0]
        return PropertyUsage(property: property, days: days, activeUsers: t[0], newUsers: t[1], sessions: t[2], events: t[3])
    }

    private func send(_ r: URLRequest) async throws -> Data {
        var req = r
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AnalyticsError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        return data
    }
}
