import Foundation
import XCTest

@testable import Mirante

@MainActor
final class BLETransportTests: XCTestCase {

    func testCCMMatchesIndependentOpenSSLVectors() throws {
        // Node/OpenSSL aes-128-ccm, 4-byte tag, 12-byte nonce, no AAD.
        // Fixed expected bytes avoid validating the implementation against itself.
        let key = Data(0..<16)
        let nonce = Data(16..<28)
        let vectors: [(Int, String)] = [
            (0, "4b50e5da"),
            (1, "03d29b1569"),
            (16, "03949b8366d10b95228555eb5849f5a9b28b91aa"),
            (31, "03949b8366d10b95228555eb5849f5a94b86e08401723c1cced19d6bef18537a697b66"),
            (48, "03949b8366d10b95228555eb5849f5a94b86e08401723c1cced19d6bef1853bb1d52ee29a7d979f452ad08b5b373f68f7447383b"),
        ]
        for (length, expected) in vectors {
            let plain = Data((0..<length).map { UInt8($0 + 32) })
            let encrypted = try XCTUnwrap(XiaomiCrypto.aesCCMEncrypt(key: key, nonce: nonce, payload: plain))
            XCTAssertEqual(encrypted.map { String(format: "%02x", $0) }.joined(), expected, "length=\(length)")
        }
    }

    func testCompleteFramesRemainSerializedAcrossSuspensions() async throws {
        let queue = XiaomiFrameWriter()
        var order: [Int] = []
        let writer: (Data) async throws -> Void = { frame in
            for byte in frame {
                order.append(Int(byte))
                await Task.yield()
            }
        }
        let first = queue.enqueue(Data([1, 2, 3]), using: writer)
        let ack = queue.enqueue(Data([4]), using: writer)
        let next = queue.enqueue(Data([5, 6]), using: writer)
        try await first.value
        try await ack.value
        try await next.value
        XCTAssertEqual(order, [1, 2, 3, 4, 5, 6])
    }

    func testQueueStopsAfterWriteFailure() async {
        let queue = XiaomiFrameWriter()
        var laterWritten = false
        let first = queue.enqueue(Data([1])) { _ in throw TransportError.deviceNotPaired }
        let next = queue.enqueue(Data([2])) { _ in laterWritten = true }
        _ = try? await first.value
        do { try await next.value; XCTFail("Failure must propagate to queued commands") }
        catch { XCTAssertFalse(laterWritten) }
    }

    func testNackDuringHandshakeFailsImmediatelyWithSequence() async {
        let session = XiaomiProtocolSession()
        session.writer = { _ in
            session.handleIncoming(XiaomiSppPacketV2.encode(type: 0, sequence: 7, payload: Data()))
        }
        do {
            try await session.runHandshake(authKey: String(repeating: "01", count: 16), phoneName: "Test", region: "BR")
            XCTFail("NACK must fail the handshake")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing packet 7"))
        }
    }

    func testEncryptedInstallWithImmediateFragmentedReplies() async throws {
        let session = XiaomiProtocolSession()
        let secret = Data(repeating: 1, count: 16)
        let watchNonce = Data(repeating: 2, count: 16)
        var phoneKey = Data()
        var watchKey = Data()
        var commands: [Int] = []
        var uploaded = 0
        var stages: [String] = []
        session.onStage = { stages.append($0) }

        func receive(_ proto: Data, encrypted: Bool) {
            let frame = XiaomiSppPacketV2.encodeData(sequence: 0, channel: .protobuf,
                opcode: encrypted ? .sendEncrypted : .sendPlaintext,
                body: proto, encryptor: { XiaomiCrypto.aesCTR(watchKey, watchKey, $0)! })
            session.handleIncoming(Data(frame.prefix(5)))
            session.handleIncoming(Data(frame.dropFirst(5)))
        }

        session.writer = { raw in
            let packet = try XCTUnwrap(XiaomiSppPacketV2.parse(raw).packet)
            if packet.type == .ack { return }
            if packet.type == .sessionConfig {
                session.handleIncoming(XiaomiSppPacketV2.encode(type: 2, sequence: 0, payload: Data([2])))
                return
            }
            if packet.payload.first == 2 { uploaded += 1; return }
            let encrypted = packet.payload[1] == 2
            let body = Data(packet.payload.dropFirst(2))
            let plain = encrypted ? try XCTUnwrap(XiaomiCrypto.aesCTR(phoneKey, phoneKey, body)) : body
            let command = try XCTUnwrap(XiaomiProto.parseCommand(plain))
            var reply = XiaomiProto.Writer()
            reply.field(1, UInt32(command.type!))
            reply.field(2, UInt32(command.subtype!))
            if command.type == 1 && command.subtype == 26 {
                let auth = try XCTUnwrap(XiaomiProto.parse(plain).first { $0.number == 3 })
                let nonceField = try XCTUnwrap(XiaomiProto.parse(auth.data).first { $0.number == 30 })
                let phoneNonce = try XCTUnwrap(XiaomiProto.parse(nonceField.data).first { $0.number == 1 }).data
                let keys = XiaomiProtocolSession.computeAuthStep3Hmac(secret: secret, phoneNonce: phoneNonce, watchNonce: watchNonce)
                watchKey = Data(keys.prefix(16))
                phoneKey = keys.subdata(in: 16..<32)
                var challenge = XiaomiProto.Writer()
                challenge.field(1, bytes: watchNonce)
                challenge.field(2, bytes: XiaomiCrypto.hmacSHA256(key: watchKey, message: watchNonce + phoneNonce))
                var authReply = XiaomiProto.Writer()
                authReply.field(31, bytes: challenge.data)
                reply.field(3, bytes: authReply.data)
            } else if command.type != 1 {
                XCTAssertTrue(encrypted, "Post-auth commands must use BLE v2 encryption")
                commands.append(command.type! * 100 + command.subtype!)
                if command.type == 22 {
                    var ack = XiaomiProto.Writer()
                    ack.field(2, UInt32(1)) // observed 10 Pro acceptance value
                    ack.field(5, UInt32(64))
                    var upload = XiaomiProto.Writer()
                    upload.field(2, bytes: ack.data)
                    reply.field(24, bytes: upload.data)
                }
            }
            receive(reply.data, encrypted: encrypted)
            await Task.yield() // ACKs arrive while a writer is suspended
        }
        try await session.runHandshake(authKey: String(repeating: "01", count: 16), phoneName: "Test", region: "BR")
        var payload = Data(repeating: 0, count: 160)
        payload.replaceSubrange(0x28..<0x2b, with: Data("123".utf8))
        try await session.installWatchface(payload: payload)
        XCTAssertEqual(commands, [404, 2200, 401, 400])
        XCTAssertGreaterThan(uploaded, 1)
        XCTAssertTrue(stages.contains("Waiting for upload parameters (22/0)"))
        XCTAssertEqual(stages.last, "Activating watchface")
        session.abort(TransportError.abortedByUser)
        session.writer = nil
    }

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
