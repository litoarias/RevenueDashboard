import Foundation
import Observation
import RevenueKit
import SwiftUI

@MainActor @Observable
final class AppModel {
    // Configuración (en Keychain salvo el vendor, que no es secreto)
    var issuerID = Keychain.get("asc.issuer") ?? ""
    var keyID = Keychain.get("asc.keyid") ?? ""
    var vendorNumber = UserDefaults.standard.string(forKey: "vendor") ?? ""
    var hasPrivateKey: Bool { Keychain.get("asc.p8") != nil }
    var googleToken: GoogleToken? = Keychain.get("google.token").flatMap { try? JSONDecoder().decode(GoogleToken.self, from: Data($0.utf8)) }

    // Estado
    /// Periodo elegido en el selector (cambia al instante).
    var days = AppModel.savedDays { didSet { UserDefaults.standard.set(days, forKey: "days") } }
    /// Periodo al que corresponden los datos mostrados (cambia solo cuando termina de cargar).
    var loadedDays = AppModel.savedDays

    private static var savedDays: Int {
        let d = UserDefaults.standard.integer(forKey: "days")
        return [7, 30, 90, 180, 365].contains(d) ? d : 30
    }
    var progress: String?
    var entries: [RevenueEntry] = []
    var isLoading = false
    var warnings: [String] = []
    var lastUpdate: Date?
    var appleError: String?
    var adsError: String?
    var adsAccount: String?

    var usage: [PropertyUsage] = []
    var usageError: String?
    var propertyCount = 0
    /// El token guardado puede no incluir el permiso de Analytics (se añadió después).
    var needsReauth: Bool { !demo && hasGoogle && UserDefaults.standard.integer(forKey: "googleScopes") < GoogleOAuthConfig.scopesVersion }

    var throughApple: Date?
    var throughAds: Date?
    var rangeFrom = Date()
    var rangeTo = Date()

    /// Último día cubierto por cada proveedor (no el último con ingresos).
    func lastDay(_ provider: String) -> Date? { provider == "Google AdMob" ? throughAds : throughApple }
    func total(_ provider: String) -> Decimal { entries.filter { $0.source.provider == provider }.reduce(0) { $0 + $1.eur } }

    /// Solo con el argumento de arranque `-demo`: datos de relleno para revisar el diseño.
    var demo = CommandLine.arguments.contains("-demo")
    var hasASC: Bool { demo || (!issuerID.isEmpty && !keyID.isEmpty && hasPrivateKey) }
    var hasGoogle: Bool { demo || googleToken != nil }

    private let cache = SalesCache(url: URL.applicationSupportDirectory.appending(path: "RevenueDashboard/sales-cache.json"))

    func saveASC(issuer: String, key: String, vendor: String, p8: String?) {
        issuerID = issuer; keyID = key; vendorNumber = vendor
        Keychain.set(issuer, for: "asc.issuer"); Keychain.set(key, for: "asc.keyid")
        UserDefaults.standard.set(vendor, forKey: "vendor")
        if let p8 { Keychain.set(p8, for: "asc.p8") }
    }

    struct ConfigBundle: Codable { let issuer: String, keyID: String, vendor: String, p8: String }

    /// Escribe un archivo con la configuración de Apple para llevarla al iPhone (contiene la clave privada).
    func exportConfigFile() -> URL? {
        guard hasASC, let p8 = Keychain.get("asc.p8"),
              let data = try? JSONEncoder().encode(ConfigBundle(issuer: issuerID, keyID: keyID, vendor: vendorNumber, p8: p8)) else { return nil }
        let url = URL.temporaryDirectory.appending(path: "revenue-config.json")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// Acepta el .json exportado o una clave .p8 suelta. Devuelve un mensaje para el usuario.
    func importFile(_ text: String) -> String {
        if let b = try? JSONDecoder().decode(ConfigBundle.self, from: Data(text.utf8)) {
            saveASC(issuer: b.issuer, key: b.keyID, vendor: b.vendor, p8: b.p8)
            return "Configuración de Apple importada. Borra el archivo cuando termines."
        }
        if text.contains("BEGIN PRIVATE KEY") { Keychain.set(text, for: "asc.p8"); return "Clave .p8 guardada. Falta Issuer ID y Key ID." }
        return "Ese archivo no es una configuración ni una clave .p8."
    }

    #if os(macOS)
    /// Importa la clave que ya usa el MCP de App Store Connect (sin sandbox en macOS).
    func importFromAscMCP() -> Bool {
        struct C: Decodable { let key_id: String, issuer_id: String, key_path: String }
        struct L: Decodable { let companies: [C] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let d = try? Data(contentsOf: home.appending(path: ".config/asc-mcp/companies.json")),
              let c = try? JSONDecoder().decode(L.self, from: d).companies.first,
              let pem = try? String(contentsOfFile: (c.key_path as NSString).expandingTildeInPath, encoding: .utf8) else { return false }
        saveASC(issuer: c.issuer_id, key: c.key_id, vendor: vendorNumber, p8: pem)
        return true
    }
    #endif

    // MARK: Google

    func signIn(using authenticate: (URL, String) async throws -> URL) async {
        do {
            let req = GoogleAuth.makeRequest()
            let callback = try await authenticate(req.url, GoogleOAuthConfig.callbackScheme)
            let token = try await GoogleAuth().exchange(code: GoogleAuth.code(from: callback), verifier: req.verifier)
            storeGoogle(token)
            UserDefaults.standard.set(GoogleOAuthConfig.scopesVersion, forKey: "googleScopes")
            requestRefresh()
        } catch { warnings = ["Google: \(error.localizedDescription)"] }
    }

    func signOutGoogle() { googleToken = nil; usage = []; Keychain.set(nil, for: "google.token"); UserDefaults.standard.removeObject(forKey: "googleScopes") }

    private func storeGoogle(_ t: GoogleToken) {
        googleToken = t
        if let d = try? JSONEncoder().encode(t) { Keychain.set(String(decoding: d, as: UTF8.self), for: "google.token") }
    }

    private func accessToken() async throws -> String {
        guard var t = googleToken else { throw AdMobError.noAccount }
        if !t.isFresh { t = try await GoogleAuth().refresh(t); storeGoogle(t) }
        return t.accessToken
    }

    // MARK: Uso (Firebase / GA4)

    private struct UsageResult { var usage: [PropertyUsage] = []; var count = 0; var error: String? }

    private func fetchUsage(days n: Int) async -> UsageResult {
        guard hasGoogle else { return UsageResult() }
        guard !needsReauth else { return UsageResult(error: "Falta el permiso de Analytics: vuelve a iniciar sesión con Google en Ajustes.") }
        let client = AnalyticsClient(accessToken: { [weak self] in try await self?.accessToken() ?? "" })
        do {
            let props = try await client.properties()
            var out: [PropertyUsage] = [], failures: [String] = []
            for chunk in stride(from: 0, to: props.count, by: 4).map({ Array(props[$0..<min($0 + 4, props.count)]) }) {
                if Task.isCancelled { return UsageResult() }
                await withTaskGroup(of: Result<PropertyUsage, Error>.self) { group in
                    for p in chunk { group.addTask { do { return .success(try await client.usage(for: p, days: n)) } catch { return .failure(error) } } }
                    for await r in group {
                        switch r { case .success(let u): out.append(u); case .failure(let e): failures.append("\(e)") }
                    }
                }
            }
            return UsageResult(usage: out.sorted { $0.activeUsers > $1.activeUsers }, count: props.count,
                               error: failures.isEmpty ? nil : "\(failures.count) de \(props.count) propiedades fallaron: \(failures[0])")
        } catch { return UsageResult(error: "\(error)") }
    }

    // MARK: Datos

    private func loadDemo(_ n: Int) {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let to = utc.startOfDay(for: .now).addingTimeInterval(-86400)
        rangeTo = to; rangeFrom = to.addingTimeInterval(-Double(n - 1) * 86400); loadedDays = n
        let apps = ["Mus - El Órdago", "TodaciApp - Todacitan", "SetReady", "Broadside - Sink the Fleet", "Pressure Control"]
        var out: [RevenueEntry] = []
        for i in 0..<n {
            let d = rangeFrom.addingTimeInterval(Double(i) * 86400)
            for (k, a) in apps.enumerated() {
                let wave = 0.6 + 0.4 * sin(Double(i + k * 3) / 2.3)
                out.append(.init(date: d, app: a, source: .ads, eur: Decimal(wave * Double(5 - k) * 0.22)))
                if (i + k) % 6 == 0 { out.append(.init(date: d, app: a, source: .subscription, eur: Decimal(1.2 + Double(k) * 0.4))) }
                if (i * 3 + k) % 11 == 0 { out.append(.init(date: d, app: a, source: .iap, eur: Decimal(2.1))) }
            }
        }
        entries = out; throughApple = to; throughAds = to; adsAccount = "pub-0000000000000000"; lastUpdate = .now
        usage = apps.enumerated().map { k, a in
            let p = AnalyticsProperty(id: "properties/\(k)", name: a, account: "Demo")
            let ds = (0..<n).map { i in UsageDay(date: rangeFrom.addingTimeInterval(Double(i) * 86400), activeUsers: Int((120 - Double(k) * 18) * (0.7 + 0.3 * sin(Double(i + k) / 2.0))), newUsers: 9, sessions: 40, events: 300) }
            return PropertyUsage(property: p, days: ds, activeUsers: ds.map(\.activeUsers).max()! * 3, newUsers: 90 - k * 10, sessions: 1200 - k * 150, events: 9000 - k * 1000)
        }
        propertyCount = apps.count
    }

    private var generation = 0
    private var refreshTask: Task<Void, Never>?

    /// Lanza un cálculo nuevo cancelando el anterior (p. ej. al cambiar de periodo).
    func requestRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    func refresh() async {
        generation += 1
        let gen = generation, n = days
        if demo { loadDemo(n); return }
        isLoading = true
        defer { if gen == generation { isLoading = false; progress = nil } }
        func current() -> Bool { gen == generation && !Task.isCancelled }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let to = utc.startOfDay(for: .now).addingTimeInterval(-86400)
        let from = to.addingTimeInterval(-Double(n - 1) * 86400)

        // Todo se calcula en variables locales y se publica de una vez al final, solo si esta petición sigue vigente.
        var sales: [SalesRow] = [], names: [String: String] = [:], ads: [AdMobRow] = []
        var warn: [String] = [], appErr: String?, adsErr: String?, thruApple: Date?, thruAds: Date?, acct = adsAccount

        let ecbDir = URL.applicationSupportDirectory.appending(path: "RevenueDashboard")
        guard let rates = try? await ECBRates.fetch(days: n, cacheDirectory: ecbDir) else {
            if current() { warnings = ["No se pudo obtener el cambio del BCE"] }
            return
        }
        guard current() else { return }

        if hasASC, let pem = Keychain.get("asc.p8") {
            let client = ASCClient(credentials: .init(issuerID: issuerID, keyID: keyID, privateKeyPEM: pem, vendorNumber: vendorNumber))
            async let nm = try? await client.appNames()
            let r = await client.sales(from: from, to: to, cache: cache, progress: { [weak self] done, total in
                Task { @MainActor in if let self, self.generation == gen { self.progress = "Apple \(done)/\(total)" } }
            })
            guard current() else { return }
            sales = r.rows; names = await nm ?? [:]; thruApple = r.through; appErr = r.errors.first
        }
        if hasGoogle {
            let client = AdMobClient(accessToken: { [weak self] in try await self?.accessToken() ?? "" })
            do {
                guard let acc = try await client.accounts().first else { throw AdMobError.noAccount }
                acct = acc.replacingOccurrences(of: "accounts/", with: "")
                ads = try await client.earnings(account: acc, from: from, to: to)
                thruAds = ads.map(\.date).max()
            } catch { adsErr = "\(error)" }
        }
        guard current() else { return }
        let usageResult = await fetchUsage(days: n)
        guard current() else { return }

        let lost = Set(sales.filter { $0.proceeds != 0 && !rates.canConvert($0.proceedsCurrency) }.map(\.proceedsCurrency))
        if !lost.isEmpty { warn.append("Sin tipo de cambio para: \(lost.sorted().joined(separator: ", "))") }

        // Publicación atómica
        entries = RevenueAggregator.combine(sales: sales, appNames: names, ads: ads, rates: rates)
        usage = usageResult.usage; propertyCount = usageResult.count; usageError = usageResult.error
        rangeFrom = from; rangeTo = to; loadedDays = n
        throughApple = thruApple; throughAds = thruAds; adsAccount = acct
        appleError = appErr; adsError = adsErr; warnings = warn
        lastUpdate = .now
    }
}
