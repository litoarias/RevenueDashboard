import CryptoKit
import Foundation
import Testing
@testable import RevenueKit

@Test func parsesSalesTSV() {
    let tsv = """
    Provider\tSKU\tTitle\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tBegin Date\tCurrency of Proceeds\tApple Identifier
    APPLE\tcom.x.sub\tApp X\tIAY\t3\t2.54\t10/14/2026\tEUR\t123
    APPLE\tcom.x.pro\tApp X\tIA1\t1\t4.24\t10/14/2026\tEUR\t123
    """
    let rows = SalesReportParser.parse(tsv)
    #expect(rows.count == 2)
    #expect(rows[0].source == .subscription)
    #expect(rows[0].proceeds == Decimal(string: "7.62"))
    #expect(rows[1].source == .iap)
}

@Test func jwtHasThreePartsAndValidSignature() throws {
    let key = P256.Signing.PrivateKey()
    let c = ASCCredentials(issuerID: "iss", keyID: "KID", privateKeyPEM: key.pemRepresentation, vendorNumber: "1")
    let token = try ASCToken.make(c)
    let parts = token.split(separator: ".")
    #expect(parts.count == 3)
    var sig = String(parts[2]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while sig.count % 4 != 0 { sig += "=" }
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: sig)!)
    #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
}

@Test func gunzipRoundTrip() throws {
    // "hola\n" gzip generado con gzip -n
    let gz = Data(base64Encoded: "H4sIAAAAAAAAA8vIz0nkAgB4rdvRBQAAAA==")!
    #expect(String(decoding: try gz.gunzipped(), as: UTF8.self) == "hola\n")
}

@Test func ecbRatesConvertWithFallback() throws {
    let xml = """
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
    <Cube><Cube time="2026-10-14"><Cube currency="USD" rate="1.2"/><Cube currency="PLN" rate="4"/></Cube>
    <Cube time="2026-10-13"><Cube currency="USD" rate="1.1"/></Cube></Cube></gesmes:Envelope>
    """
    let r = try ECBRates.parse(Data(xml.utf8))
    let d14 = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!
    let d15 = ISO8601DateFormatter().date(from: "2026-10-15T00:00:00Z")!
    #expect(r.toEUR(12, currency: "USD", on: d14) == 10)
    #expect(r.toEUR(8, currency: "PLN", on: d15) == 2)     // sin día 15: usa el último anterior
    #expect(r.toEUR(5, currency: "EUR", on: d14) == 5)
    #expect(r.toEUR(5, currency: "XXX", on: d14) == nil)
}

@Test func adMobStreamParses() throws {
    let json = """
    [{"header":{"dateRange":{}}},
     {"row":{"dimensionValues":{"DATE":{"value":"20261014"},"APP":{"value":"ca-app-pub-1~2","displayLabel":"Ordago"}},
             "metricValues":{"ESTIMATED_EARNINGS":{"microsValue":"1500000"}}}},
     {"footer":{"matchingRowCount":"1"}}]
    """
    let rows = try AdMobClient.parse(Data(json.utf8))
    #expect(rows.count == 1)
    #expect(rows[0].appName == "Ordago")
    #expect(rows[0].eur == Decimal(string: "1.5"))
}

@Test func pkceRequestIsWellFormed() throws {
    let r = GoogleAuth.makeRequest()
    let items = URLComponents(url: r.url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
    #expect(items.first { $0.name == "client_id" }?.value == GoogleOAuthConfig.clientID)
    #expect(r.verifier.count >= 43)
    let cb = URL(string: "\(GoogleOAuthConfig.callbackScheme):/oauth2redirect?code=abc&scope=x")!
    #expect(try GoogleAuth.code(from: cb) == "abc")
}

@Test func aggregatorMergesAdsAndSalesByApp() {
    let d = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!
    let rates = ECBRates(byDay: ["2026-10-14": ["USD": 2]])
    let sale = SalesRow(date: d, sku: "pro", title: "Pro", appleID: "1", parentID: "ordago-sku", productType: "IAY",
                        units: 2, proceedsPerUnit: 1, proceedsCurrency: "USD")
    let ad = AdMobRow(date: d, appID: "x", appName: "Ordago", eur: 0.5)
    let out = RevenueAggregator.combine(sales: [sale], appNames: ["ordago-sku": "Ordago: Truco"], ads: [ad], rates: rates)
    #expect(out.count == 2)
    #expect(out.allSatisfy { $0.app == "Ordago: Truco" })
    #expect(out.first { $0.source == .subscription }?.eur == 1)
    #expect(out.first { $0.source == .ads }?.eur == Decimal(string: "0.5"))
}

@Test func fallbackRatesCoverCurrenciesMissingFromECB() {
    let d = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!
    let r = ECBRates(byDay: ["2026-10-14": ["USD": 2]], fallback: ["CLP": 1000])
    #expect(r.toEUR(1421, currency: "CLP", on: d) == Decimal(string: "1.421"))
    #expect(r.canConvert("CLP") && !r.canConvert("XXX"))
}

@Test func analyticsParsesPropertiesAndUsage() throws {
    let props = """
    {"accountSummaries":[{"account":"accounts/1","displayName":"Lito","propertySummaries":[
      {"property":"properties/11","displayName":"Ordago"},{"property":"properties/22","displayName":"SetReady"}]}],"nextPageToken":"x"}
    """
    let (list, next) = try AnalyticsClient.parseProperties(Data(props.utf8))
    #expect(list.map(\.name) == ["Ordago", "SetReady"] && next == "x")

    let report = """
    {"reports":[
     {"rows":[{"dimensionValues":[{"value":"20261014"}],"metricValues":[{"value":"10"},{"value":"3"},{"value":"14"},{"value":"90"}]},
              {"dimensionValues":[{"value":"20261013"}],"metricValues":[{"value":"8"},{"value":"1"},{"value":"9"},{"value":"50"}]}]},
     {"rows":[{"metricValues":[{"value":"15"},{"value":"4"},{"value":"23"},{"value":"140"}]}]}]}
    """
    let u = try AnalyticsClient.parseUsage(Data(report.utf8), property: list[0])
    #expect(u.days.count == 2 && u.days[0].activeUsers == 8)   // ordenado por fecha
    #expect(u.activeUsers == 15 && u.newUsers == 4 && u.sessions == 23 && u.events == 140)
}

@Test func authRequestAsksForAllThreeScopes() throws {
    let items = URLComponents(url: GoogleAuth.makeRequest().url, resolvingAgainstBaseURL: false)!.queryItems!
    let scope = items.first { $0.name == "scope" }?.value ?? ""
    #expect(scope.contains("admob.readonly") && scope.contains("admob.report") && scope.contains("analytics.readonly"))
    #expect(items.first { $0.name == "prompt" }?.value == "consent")
}

@Test func downloadsCountOnlyFirstTimeDownloads() {
    let d = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!
    func row(_ type: String, _ units: Int) -> SalesRow {
        SalesRow(date: d, sku: "ordago-sku", title: "Ordago", appleID: "1", parentID: "", productType: type,
                 units: units, proceedsPerUnit: 0, proceedsCurrency: "EUR")
    }
    let out = RevenueAggregator.downloads(sales: [row("1F", 5), row("1", 2), row("7", 40), row("3F", 9), row("IAY", 3)],
                                          appNames: ["ordago-sku": "Ordago: Truco"])
    #expect(out.count == 1)
    #expect(out[0].app == "Ordago: Truco")
    #expect(out[0].units == 7)
}

@Test func downloadsUseCurrentAppNameWhenAppleParentIsWhitespace() {
    let d = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!
    let rows = ["SetReady: Adaptive Rest Timer", "SetReady: Lifting Rest Timer"].map { title in
        SalesRow(date: d, sku: "SETREADY-IOS", title: title, appleID: "6770435744", parentID: " ",
                 productType: "1", units: 2, proceedsPerUnit: 0, proceedsCurrency: " ")
    }
    let out = RevenueAggregator.downloads(sales: rows, appNames: ["SETREADY-IOS": "SetReady: Lifting Rest Timer"])
    #expect(out.count == 1)
    #expect(out.first?.app == "SetReady: Lifting Rest Timer")
    #expect(out.first?.units == 4)
}
