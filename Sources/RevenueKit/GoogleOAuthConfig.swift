import Foundation

/// Cliente OAuth tipo iOS de tu proyecto de Google Cloud (público, sin secreto; usa PKCE).
/// Se lee de la clave `GoogleClientID` del Info.plist, que viene de `GOOGLE_CLIENT_ID` en Config/*.xcconfig.
public enum GoogleOAuthConfig {
    public static let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? "YOUR-CLIENT-ID.apps.googleusercontent.com"
    /// Súbela al añadir ámbitos: obliga a volver a iniciar sesión para dar el nuevo permiso.
    public static let scopesVersion = 2
    public static let scopes = [
        "https://www.googleapis.com/auth/admob.readonly",
        "https://www.googleapis.com/auth/admob.report",
        "https://www.googleapis.com/auth/analytics.readonly",
    ]

    /// Esquema de URL de retorno: el client ID invertido.
    public static var callbackScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    public static var redirectURI: String { "\(callbackScheme):/oauth2redirect" }
}
