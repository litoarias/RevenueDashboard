import AuthenticationServices
import Charts
import RevenueKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var showSettings = false
    @State private var showSources = false
    @State private var appFilter: String?
    @State private var usageAppFilter: String?
    @State private var selected: Date?
    @State private var mode: Mode = .revenue
    enum Mode: String, CaseIterable { case revenue = "Ingresos", usage = "Uso" }

    // MARK: Datos derivados

    private var filtered: [RevenueEntry] { model.entries.filter { appFilter == nil || $0.app == appFilter } }
    private var filteredDownloads: [DownloadEntry] { model.downloads.filter { appFilter == nil || $0.app == appFilter } }
    private var shownDownloads: Int {
        let all = filteredDownloads
        guard let d = selectedDay else { return all.reduce(0) { $0 + $1.units } }
        return all.filter { gran.bucket($0.date) == d }.reduce(0) { $0 + $1.units }
    }
    private func sum(_ e: [RevenueEntry]) -> Decimal { e.reduce(0) { $0 + $1.eur } }
    private var total: Decimal { sum(filtered) }
    private var connected: Bool { model.hasASC || model.hasGoogle }

    private var allDays: [Date] {
        var out: [Date] = [], d = model.rangeFrom
        while d <= model.rangeTo { out.append(d); d = d.addingTimeInterval(86400) }
        return out
    }
    struct ChartBar: Identifiable {
        let date: Date, source: RevenueSource, eur: Double
        var id: String { "\(date.timeIntervalSince1970)|\(source.rawValue)" }
    }

    /// Una barra por cubo y origen, con orden fijo: si el orden cambiase entre redibujados (el diccionario no lo garantiza),
    /// las fases apiladas parpadearían al pasar el ratón por encima.
    private var chartData: [ChartBar] {
        struct K: Hashable { let d: Date; let s: RevenueSource }
        var acc: [K: Decimal] = [:]
        for e in filtered { acc[K(d: gran.bucket(e.date), s: e.source), default: 0] += e.eur }
        let order = RevenueSource.allCases
        return acc.map { ChartBar(date: $0.key.d, source: $0.key.s, eur: NSDecimalNumber(decimal: $0.value).doubleValue) }
            .sorted { ($0.date, order.firstIndex(of: $0.source) ?? 0) < ($1.date, order.firstIndex(of: $1.source) ?? 0) }
    }
    private var gran: Granularity { Granularity(days: model.loadedDays) }
    /// Cubo (día, semana o mes) seleccionado al arrastrar por el gráfico.
    private var selectedDay: Date? {
        guard let s = selected else { return nil }
        return Set(allDays.map(gran.bucket)).min { abs($0.timeIntervalSince(s)) < abs($1.timeIntervalSince(s)) }
    }
    private var shownEntries: [RevenueEntry] {
        guard let d = selectedDay else { return filtered }
        return filtered.filter { gran.bucket($0.date) == d }
    }
    private var parts: [(source: RevenueSource, value: Decimal)] {
        RevenueSource.allCases.map { s in (s, sum(shownEntries.filter { $0.source == s })) }
    }
    private func available(_ s: RevenueSource) -> Bool { s == .ads ? model.hasGoogle : model.hasASC }

    private var appState: SourceState { !model.hasASC ? .missing : model.appleError.map { .failed($0) } ?? .ok }
    private var adsState: SourceState { !model.hasGoogle ? .missing : model.adsError.map { .failed($0) } ?? .ok }

    // MARK: Cuerpo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                topBar
                modeSwitch
                Group {
                    if mode == .revenue {
                        VStack(alignment: .leading, spacing: 36) { hero; composition; chart; apps; footer }
                    } else {
                        UsageSection(appFilter: $usageAppFilter, openSources: { showSources = true }, openSettings: { showSettings = true }, signIn: signIn)
                    }
                }
                .opacity(model.isLoading ? 0.35 : 1)
                .animation(.easeOut(duration: 0.2), value: model.isLoading)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(alignment: .top) { Aura(shares: auraShares).offset(y: -40) }
        .background(.background)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showSources) { SourcesSheet(openSettings: { showSources = false; showSettings = true }) }
        .onChange(of: model.days) { model.requestRefresh() }
        .animation(.snappy, value: appFilter)
    }

    private func signIn() {
        Task { await model.signIn { url, scheme in try await webAuth.authenticate(using: url, callbackURLScheme: scheme) } }
    }

    private var auraShares: [(Color, Double)] {
        let t = NSDecimalNumber(decimal: total).doubleValue
        return RevenueSource.allCases.prefix(3).map { (s: RevenueSource) -> (Color, Double) in
            let v = NSDecimalNumber(decimal: sum(filtered.filter { $0.source == s })).doubleValue
            return (s.color, t > 0 ? v / t : 0)
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 26) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button { mode = m } label: {
                    Text(m.rawValue.uppercased()).font(.eyebrow(13)).tracking(1.6)
                        .foregroundStyle(mode == m ? .primary : .tertiary)
                }.buttonStyle(.plain)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 22) {
            ForEach([7, 30, 90, 180, 365], id: \.self) { d in
                Button { model.days = d } label: {
                    Text(periodShort(d)).font(.eyebrow(13)).foregroundStyle(model.days == d ? .primary : .tertiary)
                        .overlay(alignment: .bottom) { if model.days == d { Capsule().frame(height: 1.5).offset(y: 6) } }
                }.buttonStyle(.plain)
            }
            Spacer()
            if let p = model.progress { Text(p).font(.eyebrow(10)).foregroundStyle(.tertiary) }
            Button { model.requestRefresh() } label: {
                if model.isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
        .font(.system(size: 16, weight: .light)).buttonStyle(.plain).foregroundStyle(.secondary)
    }

    // MARK: Héroe

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Eyebrow(text: selectedDay.map { gran.label($0) } ?? periodEyebrow(model.loadedDays))
                if let a = appFilter {
                    Button { appFilter = nil } label: { Label(a, systemImage: "xmark").labelStyle(.titleAndIcon).font(.system(size: 11)) }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            }
            HeroAmount(value: connected ? sum(shownEntries) : nil)
            if connected {
                let days = max(1, model.loadedDays)
                Text(selectedDay == nil ? "\(eur(total / Decimal(days))) de media al día" : gran.singular)
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            } else {
                Button("Conecta una fuente") { showSources = true }.buttonStyle(.borderedProminent).tint(.primary)
            }
            if model.hasASC {
                Text("\(shownDownloads.formatted()) descargas").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Button { showSources = true } label: {
                HStack(spacing: 8) {
                    SourcePill(name: "Apple", through: model.throughApple, state: appState)
                    SourcePill(name: "AdMob", through: model.throughAds, state: adsState)
                }
            }.buttonStyle(.plain).padding(.top, 6)
            ForEach(model.warnings, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(.orange) }
        }
    }

    // MARK: Composición

    private var composition: some View {
        VStack(alignment: .leading, spacing: 16) {
            CompositionBar(parts: parts)
            HStack(alignment: .top, spacing: 0) {
                ForEach(RevenueSource.allCases.filter { $0 != .app || sum(filtered.filter { $0.source == .app }) != 0 }, id: \.self) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) { Circle().fill(s.color).frame(width: 6, height: 6); Text(s.label).font(.system(size: 12)).foregroundStyle(.secondary) }
                        Text(available(s) ? eur(parts.first { $0.source == s }?.value ?? 0) : "—")
                            .font(.serif(22, .regular)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        Text(s == .ads ? "AdMob · bruto" : "Apple · neto").font(.eyebrow(9)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Gráfico explorable

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Por \(gran.noun) · desliza para explorar")
            Chart {
                ForEach(chartData) { e in
                    BarMark(x: .value("Día", e.date, unit: gran.unit), y: .value("EUR", e.eur))
                        .foregroundStyle(e.source.color)
                        .cornerRadius(2.5)
                        .opacity(selectedDay == nil || selectedDay == e.date ? 1 : 0.25)
                }
            }
            .chartXSelection(value: $selected)
            .animation(nil, value: selected)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: gran.unit, count: gran.axisCount(days: model.loadedDays))) { value in
                    AxisValueLabel(collisionResolution: .greedy) { if let d = value.as(Date.self) { Text(gran.axisLabel(d)) } }
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
            }
            .frame(height: 170)
        }
    }

    // MARK: Ranking de apps

    private var apps: some View {
        let grouped = Dictionary(grouping: filtered, by: \.app)
        var names = Set(model.appleAppNames)
        names.formUnion(model.entries.map(\.app))
        names.formUnion(model.downloads.map(\.app))
        let selectedNames = names.filter { appFilter == nil || $0 == appFilter }
        var rows: [(name: String, entries: [RevenueEntry], sum: Decimal)] = selectedNames.map { name in
            let entries: [RevenueEntry] = grouped[name] ?? []
            return (name: name, entries: entries, sum: sum(entries))
        }
        rows.sort { lhs, rhs in
            if lhs.sum == rhs.sum { return lhs.name < rhs.name }
            return lhs.sum > rhs.sum
        }
        let top = rows.first?.sum ?? 1
        return VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: "Por app")
            if rows.isEmpty { Text("Sin datos todavía.").foregroundStyle(.secondary) }
            ForEach(rows, id: \.name) { row in
                Button { appFilter = appFilter == row.name ? nil : row.name } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name).font(.system(size: 16, weight: .medium)).lineLimit(1)
                            Spacer()
                            let dl = model.downloads.filter { $0.app == row.name }.reduce(0) { $0 + $1.units }
                            if model.hasASC { Label(dl.formatted(), systemImage: "arrow.down.circle").font(.system(size: 12)).foregroundStyle(.secondary).padding(.trailing, 10) }
                            Text(eur(row.sum)).font(.serif(18, .regular)).monospacedDigit()
                        }
                        GeometryReader { g in
                            CompositionBar(parts: RevenueSource.allCases.map { s in (s, sum(row.entries.filter { $0.source == s })) }, height: 4)
                                .frame(width: g.size.width * CGFloat(truncating: (row.sum / max(top, 0.01)) as NSDecimalNumber), alignment: .leading)
                        }.frame(height: 4)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        Button { showSources = true } label: {
            Text("AdMob es bruto estimado; Apple es neto tras comisión. Todo en EUR. Toca para ver el detalle.")
                .font(.eyebrow(10)).foregroundStyle(.tertiary).multilineTextAlignment(.leading)
        }.buttonStyle(.plain)
    }
}
