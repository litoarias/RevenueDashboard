import Foundation

public struct SalesRow: Sendable, Equatable, Codable {
    public let date: Date
    public let sku: String
    public let title: String
    public let appleID: String
    public let parentID: String
    public let productType: String
    public let units: Int
    public let proceedsPerUnit: Decimal
    public let proceedsCurrency: String

    public var proceeds: Decimal { proceedsPerUnit * Decimal(units) }

    /// Descargas nuevas (no actualizaciones ni redescargas): iPhone/iPad, universal, iPad, Mac y variantes personalizadas.
    public static let downloadTypes: Set<String> = ["1", "1F", "1T", "F1", "1E", "1EP", "1EU"]
    public var isDownload: Bool { Self.downloadTypes.contains(productType) }

    public var source: RevenueSource {
        switch productType {
        case "IAY", "IAC": .subscription
        case "IA1", "IA9": .iap
        default: .app
        }
    }
}

/// Parser del TSV de `salesReports` (SALES / SUMMARY). Localiza columnas por nombre de cabecera.
public enum SalesReportParser {
    public static func parse(_ tsv: String) -> [SalesRow] {
        let lines = tsv.split(whereSeparator: \.isNewline)
        guard let head = lines.first else { return [] }
        let cols = head.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        func idx(_ n: String) -> Int? { cols.firstIndex(of: n) }
        guard let iSKU = idx("SKU"), let iType = idx("Product Type Identifier"), let iUnits = idx("Units"),
              let iProc = idx("Developer Proceeds"), let iBegin = idx("Begin Date"),
              let iCur = idx("Currency of Proceeds") else { return [] }
        let iTitle = idx("Title"), iApple = idx("Apple Identifier"), iParent = idx("Parent Identifier")

        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd/yyyy"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")

        return lines.dropFirst().compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == cols.count, let date = fmt.date(from: f[iBegin]),
                  let units = Int(f[iUnits]) else { return nil }
            return SalesRow(
                date: date, sku: f[iSKU], title: iTitle.map { f[$0] } ?? "", appleID: iApple.map { f[$0] } ?? "", parentID: iParent.map { f[$0] } ?? "",
                productType: f[iType], units: units,
                proceedsPerUnit: Decimal(string: f[iProc], locale: Locale(identifier: "en_US_POSIX")) ?? 0,
                proceedsCurrency: f[iCur])
        }
    }
}
