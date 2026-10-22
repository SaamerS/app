import CryptoKit
import Foundation

/// Passwords for team database logins. The Mac hands the server a SCRAM-SHA-256 verifier, never the password: the
/// server stores only that, checks logins with SCRAM-SHA-256, and neither its statements nor their logs ever hold a
/// password.
public enum TeamPassword {
    /// Postgres' own count (scram_iterations).
    public static let iterations = 4096

    /// The verifier Postgres stores for `password`: `SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>` (RFC
    /// 5802 and 7677). `password` is used as its UTF-8 bytes: Binders makes its passwords of letters and digits, where
    /// SASLprep changes nothing.
    public static func verifier(for password: String, salt: [UInt8]? = nil, iterations: Int = iterations) -> String {
        let salt = salt ?? randomBytes(16)
        let salted = pbkdf2SHA256(password: Array(password.utf8), salt: salt, iterations: iterations, length: 32)
        let key = SymmetricKey(data: salted)
        let clientKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Client Key".utf8), using: key))
        let storedKey = Data(SHA256.hash(data: clientKey))
        let serverKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Server Key".utf8), using: key))
        return "SCRAM-SHA-256$\(iterations):\(Data(salt).base64EncodedString())$\(storedKey.base64EncodedString()):\(serverKey.base64EncodedString())"
    }

    /// PBKDF2 with HMAC-SHA-256 (RFC 8018).
    public static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var output: [UInt8] = []
        var block: UInt32 = 1
        while output.count < length {
            var u = Array(HMAC<SHA256>.authenticationCode(for: salt + withUnsafeBytes(of: block.bigEndian) { Array($0) }, using: key))
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for index in t.indices { t[index] ^= u[index] }
                }
            }
            output += t
            block += 1
        }
        return Array(output.prefix(length))
    }

    /// The letters and digits Binders makes passwords of: none that read alike (0 and O, 1, l and I).
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// A new password: `groups` groups of 4, with dashes between, as an invite shows a one-time password ("k7Rf-…"). 6
    /// groups (the default) is about 137 bits.
    public static func generate(groups: Int = 6) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<max(1, groups)).map { _ in
            String((0..<4).compactMap { _ in alphabet.randomElement(using: &generator) })
        }.joined(separator: "-")
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
