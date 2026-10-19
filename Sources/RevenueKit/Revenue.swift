import Foundation

public enum RevenueSource: String, Sendable, Codable, CaseIterable {
    case ads, iap, subscription, app

    /// De dónde sale el dato.
    public var provider: String { self == .ads ? "Google AdMob" : "App Store Connect" }

    public var label: String {
        switch self {
        case .ads: "Publicidad"
        case .iap: "Compras in-app"
        case .subscription: "Suscripciones"
        case .app: "Apps de pago"
        }
    }
}

public struct AdMobRow: Sendable, Equatable {
    public let date: Date
    public let appID: String
    public let appName: String
    public let eur: Decimal
}

public struct RevenueEntry: Sendable, Codable, Hashable, Identifiable {
    public let date: Date
    public let app: String
    public let source: RevenueSource
    public let eur: Decimal
    public var id: String { "\(ECBRates.dayKey(date))|\(app)|\(source.rawValue)" }
    public init(date: Date, app: String, source: RevenueSource, eur: Decimal) {
        self.date = date; self.app = app; self.source = source; self.eur = eur
    }
}

public struct DownloadEntry: Sendable, Codable, Hashable, Identifiable {
    public let date: Date
    public let app: String
    public let units: Int
    public var id: String { "\(ECBRates.dayKey(date))|\(app)" }
    public init(date: Date, app: String, units: Int) { self.date = date; self.app = app; self.units = units }
}

public enum RevenueAggregator {
    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Une ventas de Apple (netas) y AdMob (bruto estimado), todo en EUR, por día, app y origen.
    /// `appNames` mapea el SKU de la app (Parent Identifier de Apple) a su nombre.
    public static func combine(sales: [SalesRow], appNames: [String: String], ads: [AdMobRow], rates: ECBRates) -> [RevenueEntry] {
        struct Key: Hashable { let day: Date; let app: String; let source: RevenueSource }
        var acc: [Key: Decimal] = [:]
        var appleApps = Set(appNames.values)

        for r in sales where r.proceeds != 0 {
            let name = appNames[r.parentID.isEmpty ? r.sku : r.parentID] ?? (r.title.isEmpty ? r.sku : r.title)
            appleApps.insert(name)
            guard let eur = rates.toEUR(r.proceeds, currency: r.proceedsCurrency, on: r.date) else { continue }
            acc[Key(day: r.date, app: name, source: r.source), default: 0] += eur
        }

        let canon = appleApps.map { (normalize($0), $0) }
        for a in ads where a.eur != 0 {
            let n = normalize(a.appName)
            let name = canon.first { !n.isEmpty && ($0.0.hasPrefix(n) || n.hasPrefix($0.0)) }?.1 ?? a.appName
            acc[Key(day: a.date, app: name, source: .ads), default: 0] += a.eur
        }

        return acc.map { RevenueEntry(date: $0.key.day, app: $0.key.app, source: $0.key.source, eur: $0.value) }
            .sorted { ($0.date, $0.app, $0.source.rawValue) < ($1.date, $1.app, $1.source.rawValue) }
    }

    /// Descargas nuevas por día y app (mismo nombre de app que `combine`).
    public static func downloads(sales: [SalesRow], appNames: [String: String]) -> [DownloadEntry] {
        struct Key: Hashable { let day: Date; let app: String }
        var acc: [Key: Int] = [:]
        for r in sales where r.isDownload {
            // En las filas de app, el SKU de la propia app es `sku`; `parentID` va vacío.
            let name = appNames[r.parentID.isEmpty ? r.sku : r.parentID] ?? (r.title.isEmpty ? r.sku : r.title)
            acc[Key(day: r.date, app: name), default: 0] += r.units
        }
        return acc.map { DownloadEntry(date: $0.key.day, app: $0.key.app, units: $0.value) }
            .sorted { ($0.date, $0.app) < ($1.date, $1.app) }
    }
}
