import Foundation

public enum GzipError: Error { case invalidHeader, truncated }

extension Data {
    /// Descomprime gzip: quita cabecera y trailer y pasa el DEFLATE crudo a zlib.
    public func gunzipped() throws -> Data {
        let b = [UInt8](self)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw GzipError.invalidHeader }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {
            guard i + 2 <= b.count else { throw GzipError.truncated }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { throw GzipError.truncated }
        let deflate = Data(b[i..<(b.count - 8)])
        return try (deflate as NSData).decompressed(using: .zlib) as Data
    }
}
