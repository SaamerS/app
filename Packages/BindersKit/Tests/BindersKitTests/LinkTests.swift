import CryptoKit
import XCTest
@testable import BindersKit

final class LinkTests: XCTestCase {
    func testPairingLinksRoundTrip() throws {
        let pairing = LinkPairing(name: "Maya's MacBook Pro", addresses: ["192.168.1.20:7448", "100.101.102.103:7448"],
                                  secret: Link.randomBytes(16), expires: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(pairing.url.scheme, "binders")
        XCTAssertEqual(pairing.url.host, "pair")
        XCTAssertFalse(pairing.url.absoluteString.contains("+"), "URL-safe base64")
        XCTAssertEqual(LinkPairing(url: pairing.url), pairing)
        XCTAssertNil(LinkPairing(url: URL(string: "binders://pair?d=nonsense")!))
        XCTAssertNil(LinkPairing(url: URL(string: "https://binders.io")!))
        XCTAssertTrue(pairing.isExpired(at: Date(timeIntervalSince1970: 1_790_000_001)))
    }

    func testBothEndsDeriveTheSamePairingKey() {
        let secret = Link.randomBytes(16)
        let a = Link.pairingKey(secret: secret).withUnsafeBytes { Data($0) }
        let b = Link.pairingKey(secret: secret).withUnsafeBytes { Data($0) }
        let other = Link.pairingKey(secret: Link.randomBytes(16)).withUnsafeBytes { Data($0) }
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, other)
        XCTAssertEqual(a.count, 32)
    }

    func testProofsOnlyVerifyWithTheRightKey() {
        let key = SymmetricKey(size: .bits256), challenge = Link.randomBytes(32)
        let proof = Link.proof(challenge: challenge, key: key)
        XCTAssertTrue(Link.verify(proof: proof, challenge: challenge, key: key))
        XCTAssertFalse(Link.verify(proof: proof, challenge: Link.randomBytes(32), key: key))
        XCTAssertFalse(Link.verify(proof: proof, challenge: challenge, key: SymmetricKey(size: .bits256)))
    }

    func testLinesSplitAcrossPackets() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)), [Data("{\"a\":1}".utf8)])
        XCTAssertEqual(buffer.append(Data(":2}\n\n{\"c\":3}\n".utf8)), [Data("{\"b\":2}".utf8), Data("{\"c\":3}".utf8)])
        XCTAssertEqual(buffer.append(Data()), [])
    }

    func testOversizedMessagesAreDropped() {
        var buffer = LineBuffer()
        _ = buffer.append(Data(repeating: 0x41, count: Link.maximumMessageSize + 1))
        XCTAssertTrue(buffer.overflowed)
    }

    func testAddresses() {
        XCTAssertEqual(LinkClient.split("192.168.1.20:7447")?.host, "192.168.1.20")
        XCTAssertEqual(LinkClient.split("192.168.1.20:7447")?.port, 7447)
        XCTAssertEqual(LinkClient.split("[fd7a:115c::1]:7448")?.host, "fd7a:115c::1")
        XCTAssertEqual(LinkClient.split("macbook.tail1234.ts.net:7447")?.host, "macbook.tail1234.ts.net")
        XCTAssertNil(LinkClient.split("no-port"))
        // A name with a port, as a pairing code from this Mac can carry one; and IPv6 only in brackets.
        XCTAssertEqual(LinkClient.split("studio-mac.covee.example:7448")?.host, "studio-mac.covee.example")
        XCTAssertEqual(LinkClient.split("studio-mac.covee.example:7448")?.port, 7448)
        XCTAssertEqual(LinkClient.split("[fd7a:115c:a1e0::2]:7448")?.host, "fd7a:115c:a1e0::2")
        XCTAssertNil(LinkClient.split("fd7a::2:7447"), "unbracketed, it can't say where the port starts")
        XCTAssertNil(LinkClient.split("192.168.1.20:0"))
        XCTAssertNil(LinkClient.split("192.168.1.20:70000"))
        XCTAssertNil(LinkClient.split(":7447"))
    }

    /// The code every iPhone build reads: a name and a bracketed IPv6 address in `addresses` still decode, and the
    /// fields are the same five.
    func testAPairingCodeWithANameStillReads() throws {
        let pairing = LinkPairing(name: "Studio Mac", addresses: ["192.168.1.20:7448", "100.64.0.2:7448", "studio-mac.covee.example:7448",
                                                                  "[fd7a:115c:a1e0::2]:7448"],
                                  secret: Link.randomBytes(16), expires: Date(timeIntervalSince1970: 1_790_000_000))
        let decoded = try XCTUnwrap(LinkPairing(url: pairing.url))
        XCTAssertEqual(decoded.addresses.compactMap { LinkClient.split($0)?.host },
                       ["192.168.1.20", "100.64.0.2", "studio-mac.covee.example", "fd7a:115c:a1e0::2"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(pairing)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "name", "addresses", "secret", "expires"])
        XCTAssertEqual(object["version"] as? Int, 1)
    }
}
