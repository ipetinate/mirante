import Foundation
import XCTest

@testable import Mirante

final class BLETransportTests: XCTestCase {

    private func bandDevice() throws -> Device {
        try XCTUnwrap(Device.find("xiaomi_band_10_pro"))
    }

    func testValidationIsOkOnlyForOK() {
        XCTAssertTrue(TransportValidation.ok.isOk)
        XCTAssertFalse(TransportValidation.empty.isOk)
        XCTAssertFalse(TransportValidation.tooLarge(maxFacePayloadBytes).isOk)
        XCTAssertFalse(TransportValidation.wrongExtension.isOk)
        XCTAssertFalse(TransportValidation.deviceMismatch(expected: "a", found: "b").isOk)
        XCTAssertFalse(TransportValidation.notCompiled.isOk)
    }

    func testValidationEquatable() {
        XCTAssertEqual(TransportValidation.ok, .ok)
        XCTAssertEqual(TransportValidation.empty, .empty)
        XCTAssertEqual(TransportValidation.tooLarge(10), .tooLarge(10))
        XCTAssertNotEqual(TransportValidation.tooLarge(10), .tooLarge(20))
        XCTAssertEqual(
            TransportValidation.deviceMismatch(expected: "a", found: "b"),
            TransportValidation.deviceMismatch(expected: "a", found: "b")
        )
        XCTAssertNotEqual(
            TransportValidation.deviceMismatch(expected: "a", found: "b"),
            TransportValidation.deviceMismatch(expected: "a", found: "c")
        )
        XCTAssertNotEqual(TransportValidation.wrongExtension, .notCompiled)
    }

    func testValidationMessagesAreNonEmpty() {
        let validations: [TransportValidation] = [
            .ok,
            .empty,
            .tooLarge(maxFacePayloadBytes),
            .wrongExtension,
            .deviceMismatch(expected: "xiaomi_band_10_pro", found: "other"),
            .notCompiled,
        ]
        for validation in validations {
            XCTAssertFalse(validation.message.isEmpty, "message for \(validation) must not be empty")
        }
        XCTAssertTrue(TransportValidation.tooLarge(maxFacePayloadBytes).message.contains("\(maxFacePayloadBytes)"))
    }

    func testTransportErrorDescriptionsAreNonEmpty() {
        let errors: [TransportError] = [
            .validation(.empty),
            .bluetoothUnavailable,
            .deviceNotPaired,
            .transferFailed("boom"),
            .abortedByUser,
            .sendingUnavailable,
            .authKeyRequired,
            .authKeyMalformed,
            .authRejected("NO_BOUND"),
        ]
        for error in errors {
            let message = try! XCTUnwrap(error.errorDescription)
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testNoopTransportIsUnavailableAndFailsClosed() throws {
        let transport = NoopTransport()
        let device = try bandDevice()

        XCTAssertFalse(transport.isAvailable, "noop transport must never claim availability")

        XCTAssertEqual(transport.validate(payload: Data(), for: device), .empty)
        let boundary = Data(repeating: 0x41, count: maxFacePayloadBytes)
        XCTAssertEqual(transport.validate(payload: boundary, for: device), .notCompiled)
        let tooBig = Data(repeating: 0x42, count: maxFacePayloadBytes + 1)
        XCTAssertEqual(transport.validate(payload: tooBig, for: device), .tooLarge(maxFacePayloadBytes))
        let validSized = Data(repeating: 0x43, count: 100)
        XCTAssertEqual(transport.validate(payload: validSized, for: device), .notCompiled)
    }

    func testNoopTransportInstallThrowsEmpty() async throws {
        var thrown = false
        do {
            try await NoopTransport().install(payload: Data(), on: try bandDevice())
        } catch let error as TransportError {
            thrown = true
            guard case .validation(.empty) = error else {
                return XCTFail("expected .validation(.empty), got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(thrown, "install must never succeed")
    }

    func testNoopTransportInstallThrowsTooLarge() async throws {
        let payload = Data(repeating: 0x42, count: maxFacePayloadBytes + 1)
        do {
            try await NoopTransport().install(payload: payload, on: try bandDevice())
            XCTFail("install must throw for oversized payload")
        } catch let error as TransportError {
            guard case .validation(.tooLarge(let limit)) = error else {
                return XCTFail("expected .validation(.tooLarge), got \(error)")
            }
            XCTAssertEqual(limit, maxFacePayloadBytes)
        }
    }

    func testNoopTransportInstallThrowsNotCompiled() async throws {
        let payload = Data(repeating: 0x43, count: 100)
        do {
            try await NoopTransport().install(payload: payload, on: try bandDevice())
            XCTFail("install must throw for uncompiled payload")
        } catch let error as TransportError {
            guard case .validation(.notCompiled) = error else {
                return XCTFail("expected .validation(.notCompiled), got \(error)")
            }
        }
    }
}