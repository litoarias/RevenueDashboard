import AuthenticationServices
import RevenueKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var issuer = ""
    @State private var key = ""
    @State private var vendor = ""
    @State private var importing = false
    @State private var message: String?
    @State private var exportURL: URL?

    private func signIn() {
        Task { await model.signIn { url, scheme in try await webAuth.authenticate(using: url, callbackURLScheme: scheme) } }
    }

    private func check(_ ok: Bool, _ title: String) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .secondary)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Qué ves hoy", systemImage: "eye").font(.headline)
                    check(model.hasASC, "Suscripciones y compras in-app (App Store Connect)")
                    check(model.hasGoogle, "Banners (Google AdMob)")
                    Text("Cada fuente es independiente: lo que no esté conectado aparece como «—» en el panel.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    check(!issuer.isEmpty, "Issuer ID")
                    TextField("Issuer ID", text: $issuer).autocorrectionDisabled()
                    check(!key.isEmpty, "Key ID")
                    TextField("Key ID", text: $key).autocorrectionDisabled()
                    check(!vendor.isEmpty, "Vendor Number")
                    TextField("Vendor Number", text: $vendor)
                    check(model.hasPrivateKey, "Clave privada .p8")
                    Button("Importar archivo (.json de configuración o clave .p8)") { importing = true }
                    Button("Guardar") { model.saveASC(issuer: issuer, key: key, vendor: vendor, p8: nil); model.requestRefresh(); dismiss() }
                        .disabled(issuer.isEmpty || key.isEmpty || vendor.isEmpty || !model.hasPrivateKey)
                    #if os(macOS)
                    Button("Importar la clave del MCP de App Store Connect") {
                        if model.importFromAscMCP() { issuer = model.issuerID; key = model.keyID; message = "Clave importada" }
                        else { message = "No se encontró ~/.config/asc-mcp" }
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Exportar configuración para el iPhone (AirDrop)", systemImage: "iphone.and.arrow.forward") }
                        Text("El archivo contiene tu clave privada. Envíalo por AirDrop e impórtalo en el iPhone; después bórralo.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    #else
                    Text("En el iPhone lo más fácil: en la app del Mac pulsa «Exportar configuración para el iPhone», envíalo por AirDrop y usa «Importar archivo».")
                        .font(.footnote).foregroundStyle(.secondary)
                    #endif
                } header: {
                    Text("App Store Connect · suscripciones y compras in-app")
                } footer: {
                    Text("Issuer ID y Key ID: App Store Connect → Usuarios y acceso → Integraciones → Claves de la App Store Connect API. La .p8 solo se descarga una vez. Vendor Number: Ventas y tendencias.")
                }

                Section {
                    if model.hasGoogle {
                        Label(model.adsAccount.map { "Conectado · cuenta \($0)" } ?? "Conectado", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        if model.needsReauth {
                            Label("Falta el permiso de Analytics (Firebase)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Button(model.needsReauth ? "Añadir permiso de Analytics" : "Volver a conectar (renovar permisos)") { signIn() }
                        Button("Desconectar", role: .destructive) { model.signOutGoogle() }
                    } else {
                        Button("Iniciar sesión con Google") { signIn() }
                    }
                } header: {
                    Text("Google AdMob · banners")
                } footer: {
                    Text("Solo lectura: AdMob (admob.readonly, admob.report) y Firebase Analytics (analytics.readonly). Al conectar, Google te mostrará los tres permisos. Mientras la app de Google esté en modo Prueba, hay que volver a entrar cada 7 días.")
                }

                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .navigationTitle("Ajustes")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, UTType(filenameExtension: "p8") ?? .data, .plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { message = "No se pudo leer el archivo"; return }
                message = model.importFile(text)
                issuer = model.issuerID; key = model.keyID; vendor = model.vendorNumber
                if model.hasASC { model.requestRefresh() }
            }
            .onAppear {
                issuer = model.issuerID; key = model.keyID; vendor = model.vendorNumber
                #if os(macOS)
                exportURL = model.exportConfigFile()
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }
}
