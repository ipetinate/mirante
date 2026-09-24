import Foundation
import XCTest

@testable import Mirante

final class AuthKeyStoreTests: XCTestCase {

    // MARK: - Validation

    func testValidKeysAccepted() {
        XCTAssertTrue(AuthKeyStore.isValid("0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(AuthKeyStore.isValid("0123456789ABCDEF0123456789ABCDEF"))
        XCTAssertTrue(AuthKeyStore.isValid("AbCdEf0123456789AbCdEf0123456789"))
        // Surrounding whitespace is allowed and trimmed.
        XCTAssertTrue(AuthKeyStore.isValid(" 0123456789abcdef0123456789abcdef "))
    }

    func testInvalidKeysRejected() {
        XCTAssertFalse(AuthKeyStore.isValid(""))
        XCTAssertFalse(AuthKeyStore.isValid("0"))
        XCTAssertFalse(AuthKeyStore.isValid(String(repeating: "0", count: 31)))
        XCTAssertFalse(AuthKeyStore.isValid(String(repeating: "0", count: 33)))
        XCTAssertFalse(AuthKeyStore.isValid("0123456789abcdef0123456789abcdeg")) // g is not hex
        XCTAssertFalse(AuthKeyStore.isValid("0123456789abcdef 0123456789abcdef")) // internal space
        XCTAssertFalse(AuthKeyStore.isValid("0x123456789abcdef123456789abcdef0")) // 0x prefix
    }

    // MARK: - Normalization

    func testNormalization() {
        XCTAssertEqual(AuthKeyStore.normalized(" 0123456789ABCDEF0123456789ABCDEF "),
                       "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(AuthKeyStore.normalized("\n\tabcd\n"), "abcd")
    }

    // MARK: - Transport gating

    @MainActor
    func testSetAuthKeyAcceptsValidNormalized() {
        let transport = BandTransport()
        let key = transport.setAuthKey(" 0123456789ABCDEF0123456789ABCDEF ")
        XCTAssertEqual(key, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(transport.authKey, key)
    }

    @MainActor
    func testSetAuthKeyRejectsInvalidAndKeepsPrevious() {
        let transport = BandTransport()
        let previous = transport.setAuthKey("0123456789abcdef0123456789abcdef")
        XCTAssertNotNil(previous)

        XCTAssertNil(transport.setAuthKey("zz"), "malformed key must be rejected")
        XCTAssertEqual(transport.authKey, previous, "existing key must survive a rejected write")
    }

    @MainActor
    func testSetAuthKeyNilClears() {
        let transport = BandTransport()
        XCTAssertNotNil(transport.setAuthKey("0123456789abcdef0123456789abcdef"))
        transport.setAuthKey(nil)
        XCTAssertNil(transport.authKey)
    }

    @MainActor
    func testInstallWithoutAuthKeyThrowsAuthKeyRequired() async {
        let transport = BandTransport()
        transport.setAuthKey(nil) // the Keychain may hold a key from another test run
        let device = Device.all[0]
        let payload = CompiledFaceMagic.bytes + Data(repeating: 0x00, count: 100)

        do {
            try await transport.install(payload: Data(payload), on: device)
            XCTFail("install must not succeed without an auth key")
        } catch let error as TransportError {
            guard case .authKeyRequired = error else {
                return XCTFail("expected .authKeyRequired, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}