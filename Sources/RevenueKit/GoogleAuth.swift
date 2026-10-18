import CryptoKit
import Foundation

public struct GoogleToken: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiry: Date
    public var isFresh: Bool { expiry > Date().addingTimeInterval(60) }
}

public enum GoogleAuthError: Error { case badCallback, http(Int, String) }

/// OAuth 2.0 con PKCE para el cliente tipo iOS (sin client secret).
public struct GoogleAuth: Sendable {
    public var session: URLSession = .shared
    public init() {}

    public struct Request: Sendable { public let url: URL; public let verifier: String }

    public static func makeRequest() -> Request {
        var bytes = [UInt8](repeating: 0, count: 48)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let verifier = Data(bytes).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: GoogleOAuthConfig.clientID),
            .init(name: "redirect_uri", value: GoogleOAuthConfig.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleOAuthConfig.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return Request(url: c.url!, verifier: verifier)
    }

    public static func code(from callback: URL) throws -> String {
        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else { throw GoogleAuthError.badCallback }
        return code
    }

    public func exchange(code: String, verifier: String) async throws -> GoogleToken {
        try await token(["code": code, "code_verifier": verifier, "grant_type": "authorization_code",
                         "redirect_uri": GoogleOAuthConfig.redirectURI], keeping: nil)
    }

    public func refresh(_ t: GoogleToken) async throws -> GoogleToken {
        try await token(["refresh_token": t.refreshToken, "grant_type": "refresh_token"], keeping: t.refreshToken)
    }

    private func token(_ form: [String: String], keeping refresh: String?) async throws -> GoogleToken {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var f = form
        f["client_id"] = GoogleOAuthConfig.clientID
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = Data(f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GoogleAuthError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        struct R: Decodable { let access_token: String; let expires_in: Double; let refresh_token: String? }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard let rt = r.refresh_token ?? refresh else { throw GoogleAuthError.badCallback }
        return GoogleToken(accessToken: r.access_token, refreshToken: rt, expiry: Date().addingTimeInterval(r.expires_in))
    }
}
