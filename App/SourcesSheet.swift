import RevenueKit
import SwiftUI

/// Detalle de cada fuente: qué aporta, en qué estado está y cómo se calcula.
struct SourcesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let openSettings: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    block(name: "App Store Connect", icon: "app.badge.fill", tint: .blue,
                          provides: "Suscripciones, compras in-app y apps de pago. Son las «ganancias del desarrollador»: neto tras la comisión de Apple.",
                          state: !model.hasASC ? .missing : model.appleError.map { .failed($0) } ?? .ok,
                          through: model.throughApple, total: model.total("App Store Connect"),
                          missing: "Falta Issuer ID, Key ID o la clave .p8.")
                    block(name: "Google AdMob", icon: "megaphone.fill", tint: .orange,
                          provides: "Banners. Ingresos estimados brutos; Google los entrega ya en EUR y pueden ajustarse días después." + (model.adsAccount.map { " Cuenta \($0)." } ?? ""),
                          state: !model.hasGoogle ? .missing : model.adsError.map { .failed($0) } ?? .ok,
                          through: model.throughAds, total: model.total("Google AdMob"),
                          missing: "Falta iniciar sesión con Google.")
                    block(name: "Firebase Analytics", icon: "chart.xyaxis.line", tint: .yellow,
                          provides: "Usuarios activos, nuevos, sesiones y eventos de todas tus propiedades GA4/Firebase. Se listan solas, sin buscar app por app." + (model.propertyCount > 0 ? " \(model.propertyCount) propiedades." : ""),
                          state: !model.hasGoogle ? .missing : model.needsReauth ? .failed("Falta el permiso de Analytics. Vuelve a iniciar sesión con Google en Ajustes.") : model.usageError.map { .failed($0) } ?? .ok,
                          through: model.rangeTo, total: 0, missing: "Falta iniciar sesión con Google.", showTotal: false)
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "Cómo se calcula")
                        Text("Apple se convierte a EUR con el cambio diario del BCE (y un respaldo para divisas que el BCE no publica). Los informes de Apple llegan con ~1 día de retraso.").font(.callout)
                        Text("El total suma ambas fuentes aunque AdMob sea bruto y Apple neto. Una app de AdMob se une a la de Apple si sus nombres coinciden.").font(.callout)
                    }.foregroundStyle(.secondary)
                    Button("Abrir ajustes", action: openSettings).buttonStyle(.borderedProminent).tint(.primary)
                }
                .padding(24)
            }
            .navigationTitle("Fuentes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private func block(name: String, icon: String, tint: Color, provides: String, state: SourceState, through: Date?, total: Decimal, missing: String, showTotal: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(name).font(.system(size: 20, weight: .semibold))
                Spacer()
                SourcePill(name: "", through: through, state: state).labelsHidden()
            }
            Text(provides).font(.callout).foregroundStyle(.secondary)
            switch state {
            case .ok: Text(showTotal ? "Datos hasta \(dayLabel(through)) · \(eur(total)) en \(model.days) días" : "Datos hasta \(dayLabel(through))").font(.callout).monospacedDigit()
            case .missing: Text(missing).font(.callout).foregroundStyle(.orange)
            case .failed(let why): Text(why).font(.callout).foregroundStyle(.red).lineLimit(4)
            }
        }
    }
}

private extension SourcePill { func labelsHidden() -> some View { self } }
