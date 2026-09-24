import XCTest

@testable import Mirante

@MainActor
final class BandMatcherTests: XCTestCase {

    func testExactCatalogNameMatches() {
        XCTAssertEqual(BandMatcher.matches(advertisedName: "Xiaomi Band 9")?.id, "xiaomi_band_9")
        XCTAssertEqual(BandMatcher.matches(advertisedName: "Redmi Watch 5")?.id, "redmi_watch_5")
    }

    func testExactSmartBandNameMatches() {
        XCTAssertEqual(
            BandMatcher.matches(advertisedName: "Xiaomi Smart Band 10 Pro")?.id,
            "xiaomi_band_10_pro"
        )
    }

    func testAdvertisedSmartPrefixMatchesPlainCatalogName() {
        XCTAssertEqual(BandMatcher.matches(advertisedName: "Xiaomi Smart Band 10")?.id, "xiaomi_band_10")
        XCTAssertEqual(BandMatcher.matches(advertisedName: "Xiaomi Smart Band 9")?.id, "xiaomi_band_9")
    }

    func testLongestCatalogNameWins() {
        XCTAssertEqual(BandMatcher.matches(advertisedName: "Xiaomi Band 9 Pro Extra")?.id, "xiaomi_band_9_pro")
    }

    func testUnknownDeviceReturnsNil() {
        XCTAssertNil(BandMatcher.matches(advertisedName: "Sony WH-1000XM5"))
        XCTAssertNil(BandMatcher.matches(advertisedName: "   "))
        XCTAssertNil(BandMatcher.matches(advertisedName: ""))
    }

    func testIsLikelyBandKeywords() {
        XCTAssertTrue(BandMatcher.isLikelyBand(advertisedName: "Amazfit Band 7"))
        XCTAssertTrue(BandMatcher.isLikelyBand(advertisedName: "Mi Smart Band 6"))
        XCTAssertFalse(BandMatcher.isLikelyBand(advertisedName: "Sony WH-1000XM5"))
    }

    func testInstallFailsClosedWithNotCompiled() async {
        let transport = BandTransport()
        do {
            try await transport.install(payload: Data("not-a-face".utf8), on: Device.all[0])
            XCTFail("install must never succeed")
        } catch let error as TransportError {
            guard case .validation(let validation) = error else {
                return XCTFail("expected validation error, got \(error)")
            }
            XCTAssertEqual(validation, .notCompiled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testInstallRejectsEmptyPayload() async {
        let transport = BandTransport()
        do {
            try await transport.install(payload: Data(), on: Device.all[0])
            XCTFail("install must never succeed")
        } catch let error as TransportError {
            guard case .validation(let validation) = error else {
                return XCTFail("expected validation error, got \(error)")
            }
            XCTAssertEqual(validation, .empty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testValidateMatchesNoopPolicy() {
        let transport = BandTransport()
        XCTAssertEqual(transport.validate(payload: Data(), for: Device.all[0]), .empty)
        XCTAssertEqual(transport.validate(payload: Data(repeating: 1, count: maxFacePayloadBytes + 1), for: Device.all[0]), .tooLarge(maxFacePayloadBytes))
        XCTAssertEqual(transport.validate(payload: Data("face".utf8), for: Device.all[0]), .notCompiled)
        XCTAssertFalse(transport.isAvailable)
    }
}
