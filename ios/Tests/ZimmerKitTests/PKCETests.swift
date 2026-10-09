import XCTest
@testable import ZimmerKit

final class PKCETests: XCTestCase {
    func testSHA256MatchesTheFIPSVectors() {
        let hex = { (bytes: [UInt8]) in bytes.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(SHA256Digest.hash(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(SHA256Digest.hash([])),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // Two blocks: the padding has to spill into a second one.
        XCTAssertEqual(hex(SHA256Digest.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testTheChallengeMatchesRFC7636AppendixB() {
        XCTAssertEqual(PKCEPair.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAGeneratedPairHasTheShapeZimmerAccepts() {
        let pair = PKCEPair.generate()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertEqual(pair.verifier.count, 43)
        XCTAssertEqual(pair.challenge.count, 43)
        XCTAssertTrue(pair.challenge.unicodeScalars.allSatisfy(allowed.contains))
        XCTAssertNotEqual(pair.verifier, PKCEPair.generate().verifier)
    }
}
