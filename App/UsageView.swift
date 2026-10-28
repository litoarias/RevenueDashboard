import Charts
import RevenueKit
import SwiftUI

/// Pestaña «Uso»: usuarios de Firebase Analytics (GA4) de todas tus apps, sin buscar una por una.
struct UsageSection: View {
    @Environment(AppModel.self) private var model
    @Binding var appFilter: String?
    let openSources: () -> Void
    let openSettings: () -> Void
    let signIn: () -> Void
    @State private var selected: Date?

    private let tint = Color(red: 1.0, green: 0.82, blue: 0.25)

    private var props: [PropertyUsage] { model.usage.filter { appFilter == nil || $0.id == appFilter } }
    private var gran: Granularity { Granularity(days: model.loadedDays) }
    /// Usuarios activos por cubo: suma de apps cada día; en semanas/meses, la media diaria (no se suman días).
    private var daily: [(date: Date, users: Int)] {
        let perDay = Dictionary(grouping: props.flatMap(\.days), by: \.date).mapValues { $0.reduce(0) { $0 + $1.activeUsers } }
        return Dictionary(grouping: perDay.keys, by: gran.bucket).map { bucket, days in
            (bucket, gran == .day ? perDay[days[0]] ?? 0 : days.reduce(0) { $0 + (perDay[$1] ?? 0) } / max(days.count, 1))
        }.sorted { $0.0 < $1.0 }
    }
    private var selectedDay: Date? {
        guard let s = selected else { return nil }
        return daily.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) }?.date
    }
    private var users: Int { selectedDay.flatMap { d in daily.first { $0.date == d }?.users } ?? props.reduce(0) { $0 + $1.activeUsers } }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            if !model.hasGoogle {
                gate("Inicia sesión con Google para ver Firebase Analytics.", button: "Iniciar sesión con Google", action: signIn)
            } else if model.needsReauth {
                gate("Falta un permiso nuevo (Analytics). Pulsa y Google te mostrará los permisos de AdMob y Analytics; acepta ambos.", button: "Añadir permiso de Analytics", action: signIn)
            } else {
                hero
                chart
                ranking
                if let e = model.usageError { Text(e).font(.footnote).foregroundStyle(.orange) }
                Text("Cada app cuenta sus propios usuarios activos: quien usa dos apps suma dos veces. Datos de GA4 hasta ayer.")
                    .font(.eyebrow(10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func gate(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HeroNumber(text: "—")
            Text(text).foregroundStyle(.secondary)
            Button(button, action: action).buttonStyle(.borderedProminent).tint(.primary)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let id = appFilter, let property = model.usage.first(where: { $0.id == id })?.property {
                Button { appFilter = nil } label: {
                    Label(property.name, systemImage: "xmark").font(.system(size: 11))
                }.buttonStyle(.bordered).controlSize(.mini)
            }
            Eyebrow(text: selectedDay.map { gran.label($0) } ?? "usuarios activos · \(props.count) apps · \(periodShort(model.loadedDays))")
            HeroNumber(text: count(users))
            let new = props.reduce(0) { $0 + $1.newUsers }, sessions = props.reduce(0) { $0 + $1.sessions }
            Text(selectedDay == nil ? "\(count(new)) nuevos · \(count(sessions)) sesiones" : gran == .day ? "usuarios activos ese día" : "usuarios activos al día de media \(gran.singular)")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Por \(gran.noun) · desliza para explorar")
            Chart(daily, id: \.date) { d in
                BarMark(x: .value("Día", d.date, unit: gran.unit), y: .value("Usuarios", d.users))
                    .foregroundStyle(tint).cornerRadius(2.5)
                    .opacity(selectedDay == nil || selectedDay == d.date ? 1 : 0.25)
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

    private var ranking: some View {
        let rows = props
        let top = max(rows.first?.activeUsers ?? 1, 1)
        return VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: "Por app")
            if rows.isEmpty { Text(model.isLoading ? "Cargando…" : "Sin actividad en este periodo.").foregroundStyle(.secondary) }
            ForEach(rows) { u in
                Button { appFilter = appFilter == u.id ? nil : u.id } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(u.property.name).font(.system(size: 16, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(count(u.activeUsers)).font(.serif(18, .regular)).monospacedDigit()
                        }
                        GeometryReader { g in
                            Capsule().fill(tint).frame(width: g.size.width * CGFloat(u.activeUsers) / CGFloat(top), height: 4)
                        }.frame(height: 4)
                        Text("\(count(u.newUsers)) nuevos · \(count(u.sessions)) sesiones · \(count(u.events)) eventos")
                            .font(.eyebrow(10)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}
