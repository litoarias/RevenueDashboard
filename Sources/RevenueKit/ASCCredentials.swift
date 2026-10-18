import CryptoKit
import Foundation

public struct ASCCredentials: Sendable {
    public let issuerID: String
    public let keyID: String
    public let privateKeyPEM: String
    public let vendorNumber: String

    public init(issuerID: String, keyID: String, privateKeyPEM: String, vendorNumber: String) {
        self.issuerID = issuerID
        self.keyID = keyID
        self.privateKeyPEM = privateKeyPEM
        self.vendorNumber = vendorNumber
    }
}

/// Firma el JWT ES256 que exige la App Store Connect API (caducidad máx. 20 min).
public enum ASCToken {
    public static func make(_ c: ASCCredentials, now: Date = .now, lifetime: TimeInterval = 15 * 60) throws -> String {
        let key = try P256.Signing.PrivateKey(pemRepresentation: c.privateKeyPEM)
        let iat = Int(now.timeIntervalSince1970)
        let header = ["alg": "ES256", "kid": c.keyID, "typ": "JWT"]
        let payload: [String: Any] = ["iss": c.issuerID, "iat": iat, "exp": iat + Int(lifetime), "aud": "appstoreconnect-v1"]
        let h = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys).base64URL
        let p = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys).base64URL
        let signature = try key.signature(for: Data("\(h).\(p)".utf8)).rawRepresentation
        return "\(h).\(p).\(signature.base64URL)"
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
