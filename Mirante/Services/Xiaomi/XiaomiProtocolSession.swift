import Foundation
import Security

/// Drives the Xiaomi protocol-v2 session over a connected BLE pipe: session
/// start, encrypted auth handshake, then a watchface install (installStart ->
/// upload request -> chunked DATA-channel transfer -> activate).
///
/// The transport supplies plain frame writes via `writer` and feeds received
/// bytes through `handleIncoming(_:)`. Everything runs on the MainActor, so
/// the pending-reply continuations below are safe to resume from parse callbacks.
@MainActor
final class XiaomiProtocolSession {
    /// Writes one complete, already-framed packet (the transport chunks it into
    /// ATT writes itself).
    var writer: ((Data) async throws -> Void)?
    /// 0...1 upload progress (per DATA parts sent).
    var onProgress: ((Double) -> Void)?
    var onStage: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private let writes = XiaomiFrameWriter()
    private var failure: Error?
    private var stage = "Starting session"

    private func setStage(_ value: String) {
        stage = value
        onStage?(value)
        onDiagnostic?(value)
    }

    func abort(_ error: Error) {
        failure = error
        writes.fail(error)
        let pending = pendings
        pendings.removeAll()
        for gate in pending { gate.fail(error) }
    }

    private func write(_ frame: Data) async throws {
        if let failure { throw failure }
        guard let writer else { throw TransportError.transferFailed("Transport is not ready.") }
        try await writes.enqueue(frame, using: writer).value
    }

    private(set) var authenticated = false

    private var rxBuffer = Data()
    private var sequenceCounter = 0
    private var encryptionGenerated = false

    private var encryptionKey = Data(repeating: 0, count: 16)
    private var decryptionKey = Data(repeating: 0, count: 16)

    private var pendings: [ReplyGate] = []

    static let replyTimeout: UInt64 = 25_000_000_000

    // MARK: - Outbound

    private func nextSequence() -> Int {
        let seq = sequenceCounter
        sequenceCounter += 1
        return seq
    }

    private func sendCommand(_ proto: Data, encrypted: Bool) async throws {
        let channel = XiaomiSppPacketV2.Channel.protobuf
        let opcode: XiaomiSppPacketV2.OpCode = encrypted ? .sendEncrypted : .sendPlaintext
        let encodedBody: Data
        if encrypted {
            guard let ciphertext = XiaomiCrypto.aesCTR(encryptionKey, encryptionKey, proto) else {
                throw TransportError.transferFailed("Unable to encrypt command.")
            }
            encodedBody = ciphertext
        } else { encodedBody = proto }
        let frame = XiaomiSppPacketV2.encodeData(
            sequence: nextSequence(),
            channel: channel,
            opcode: opcode,
            body: encodedBody,
            encryptor: { $0 }
        )
        if let command = XiaomiProto.parseCommand(proto) {
            onDiagnostic?("TX command type=\(command.type ?? -1) subtype=\(command.subtype ?? -1) encrypted=\(encrypted)")
        }
        try await write(frame)
    }

    private func sendPlainCommand(_ proto: Data) async throws {
        try await sendCommand(proto, encrypted: false)
    }

    private func sendEncryptedCommand(_ proto: Data) async throws {
        try await sendCommand(proto, encrypted: encryptionGenerated)
    }

    private func sendDataChunk(_ chunk: Data) async throws {
        let frame = XiaomiSppPacketV2.encodeData(
            sequence: nextSequence(),
            channel: .data,
            opcode: .sendPlaintext,
            body: chunk,
            encryptor: { $0 }
        )
        try await write(frame)
    }

    // MARK: - Replies

    /// Registers a reply gate and returns it. Callers mount the gate BEFORE
    /// sending the command that triggers the reply, then `await gate.wait()`.
    /// Registering before the write closes the lost-wakeup window in which a
    /// fast reply could arrive while the previous code was still setting up its
    /// continuation, which surfaced as spurious "The band did not reply in
    /// time." timeouts.
    private func mountReply(_ predicate: @escaping (XiaomiProto.CommandInfo) -> Bool) -> ReplyGate {
        let gate = ReplyGate(predicate: predicate, timeoutNanoseconds: Self.replyTimeout, stage: stage)
        pendings.append(gate)
        return gate
    }

    private func resumeMatching(_ event: XiaomiProto.CommandInfo) {
        guard let index = pendings.firstIndex(where: { $0.accepts(event) }) else { return }
        let gate = pendings.remove(at: index)
        gate.resolve(event)
    }

    /// A request/reply gate. `mountReply` registers it with the session before
    /// the command is written; incoming events feed back through `accepts` /
    /// `resolve`. If the reply arrives before `wait()` is called it is buffered
    /// so the reply is never dropped, and if `wait()` is already running the
    /// pending continuation resumes immediately.
    @MainActor
    private final class ReplyGate {
        private let predicate: (XiaomiProto.CommandInfo) -> Bool
        private let timeoutNanoseconds: UInt64
        private var continuation: CheckedContinuation<XiaomiProto.CommandInfo, Error>?
        private var buffered: XiaomiProto.CommandInfo?
        private var timeoutTask: Task<Void, Never>?
        private var failure: Error?
        private let stage: String

        init(predicate: @escaping (XiaomiProto.CommandInfo) -> Bool, timeoutNanoseconds: UInt64, stage: String) {
            self.predicate = predicate
            self.timeoutNanoseconds = timeoutNanoseconds
            self.stage = stage
        }

        func fail(_ error: Error) {
            failure = error
            timeoutTask?.cancel()
            timeoutTask = nil
            let pending = continuation
            continuation = nil
            pending?.resume(throwing: error)
        }

        func accepts(_ event: XiaomiProto.CommandInfo) -> Bool {
            predicate(event)
        }

        /// Delivers the matching reply and cancels the timeout. Safe to call
        /// before `wait()` (the reply is buffered) or after (the continuation
        /// resumes).
        func resolve(_ event: XiaomiProto.CommandInfo) {
            timeoutTask?.cancel()
            timeoutTask = nil
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: event)
            } else {
                buffered = event
            }
        }

        func wait() async throws -> XiaomiProto.CommandInfo {
            if let failure { throw failure }
            if let buffered { return buffered }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 25_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    guard let continuation = self.continuation else { return }
                    self.continuation = nil
                    self.timeoutTask = nil
                    continuation.resume(throwing: TransportError.transferFailed("No reply while: \(self.stage)."))
                }
                self.timeoutTask = task
            }
        }
    }

    // MARK: - Inbound

    func handleIncoming(_ raw: Data) {
        rxBuffer.append(raw)
        while true {
            let result = XiaomiSppPacketV2.parse(rxBuffer)
            guard result.consumed > 0 else {
                if rxBuffer.count >= 8 { rxBuffer.removeFirst(0) }
                return
            }
            let chunk = rxBuffer.prefix(result.consumed)
            rxBuffer.removeFirst(result.consumed)
            guard result.consumed >= 8, let packet = result.packet else {
                onDiagnostic?("Discarded invalid frame (\(result.consumed) bytes)")
                continue
            }
            process(packet, bytes: Data(chunk))
            if result.consumed < 8 { continue }
        }
    }

    private func process(_ packet: XiaomiSppPacketV2.Packet, bytes: Data) {
        guard let type = packet.type else { return }
        if stage != "Uploading watchface", type == .data {
            onDiagnostic?("RX frame sequence=\(packet.sequence) channel=\(packet.payload.first.map { Int($0 & 15) } ?? -1) opcode=\(packet.payload.dropFirst().first.map(Int.init) ?? -1) bytes=\(packet.payload.count)")
        }
        switch type {
        case .nack:
            abort(TransportError.transferFailed("The band requested missing packet \(packet.sequence) during \(stage). Reconnect before retrying."))
        case .sessionConfig:
            var event = XiaomiProto.CommandInfo()
            event.isSessionConfig = true
            resumeMatching(event)
        case .ack:
            if stage != "Uploading watchface" { onDiagnostic?("RX ACK sequence=\(packet.sequence)") }
        case .data:
            handleDataPacket(packet)
        }
    }

    private func handleDataPacket(_ packet: XiaomiSppPacketV2.Packet) {
        guard packet.payload.count >= 2 else { return }
        let channelRaw = Int(packet.payload[packet.payload.startIndex] & 0x0F)
        let opcode = Int(packet.payload[packet.payload.startIndex + 1])
        let body = packet.payload.dropFirst(2)

        guard channelRaw == XiaomiSppPacketV2.Channel.protobuf.rawValue else {
            // activity/data channels carry bulk payloads Mirante does not consume
            ack(packet.sequence)
            return
        }

        let plain: Data
        if opcode == XiaomiSppPacketV2.OpCode.sendEncrypted.rawValue,
           let decrypted = XiaomiCrypto.aesCTR(decryptionKey, decryptionKey, Data(body)) {
            plain = decrypted
        } else {
            plain = Data(body)
        }

        ack(packet.sequence)

        var command: XiaomiProto.CommandInfo
        guard let parsed = XiaomiProto.parseCommand(plain) else {
            // not a protobuf command (e.g. a version banner) — nothing to do
            return
        }
        command = parsed
        command.raw = plain
        onDiagnostic?("RX command type=\(command.type ?? -1) subtype=\(command.subtype ?? -1) status=\(command.status.map(String.init) ?? "absent")")
        resumeMatching(command)
    }

    private func ack(_ sequence: Int) {
        let frame = XiaomiSppPacketV2.encodeAck(sequence: sequence)
        if let writer {
            // Enqueue synchronously, before resolving the reply gate. The next
            // command cannot overtake or split this ACK at an ATT boundary.
            let task = writes.enqueue(frame, using: writer)
            Task { [weak self] in
                do { try await task.value }
                catch { self?.abort(error) }
            }
        }
    }

    // MARK: - Auth handshake

    /// Runs session start + encrypted handshake. The transport must already be
    /// connected with notification enabled on the RX characteristic.
    func runHandshake(authKey: String, phoneName: String, region: String) async throws {
        setStage("Starting BLE v2 session")
        // Mount the reply gate before writing so a fast session-config
        // response (or first command) is never lost between the write and the
        // continuation registration.
        let readyGate = mountReply { $0.isSessionConfig || $0.type != nil }
        try await write(XiaomiSppPacketV2.encodeSessionStartRequest())
        _ = try await readyGate.wait()

        // Step 1: send our nonce and await the watch nonce.
        let secret = try Self.hexKey(authKey)
        var phoneNonce = Data(count: 16)
        let nonceLength = phoneNonce.count
        let status: OSStatus = phoneNonce.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecMemoryError }
            return SecRandomCopyBytes(kSecRandomDefault, nonceLength, baseAddress)
        }
        guard status == errSecSuccess else {
            throw TransportError.transferFailed("Unable to generate a secure nonce.")
        }

        setStage("Exchanging authentication challenge")
        let nonceGate = mountReply {
            $0.type == 1 && ($0.auth?.watchNonce?.isEmpty == false)
        }
        try await sendPlainCommand(XiaomiProto.buildNonceCommand(nonce: phoneNonce))

        let nonceReply = try await nonceGate.wait()
        guard let watchNonce = nonceReply.auth?.watchNonce,
              let watchHmac = nonceReply.auth?.watchHmac else {
            throw TransportError.authRejected("The band did not return a nonce challenge.")
        }

        // Derive session keys from the auth key + both nonces (step-3 HMAC).
        let output = Self.computeAuthStep3Hmac(secret: secret, phoneNonce: phoneNonce, watchNonce: watchNonce)
        guard output.count == 64 else {
            throw TransportError.authRejected("Key derivation produced malformed output.")
        }
        decryptionKey = output.prefix(16)
        encryptionKey = output.subdata(in: output.startIndex + 16 ..< output.startIndex + 32)
        let encryptionNonce = output.subdata(in: output.startIndex + 36 ..< output.startIndex + 40)

        // Verify the watch's MAC over (watchNonce || phoneNonce).
        var confirmationInput = watchNonce
        confirmationInput.append(phoneNonce)
        let confirmation = XiaomiCrypto.hmacSHA256(key: decryptionKey, message: confirmationInput)
        guard confirmation == watchHmac else {
            throw TransportError.authRejected("The band rejected the auth key.")
        }

        // Step 3: encrypt our device info under AES-CCM and send it back.
        let deviceInfo = XiaomiProto.buildAuthDeviceInfo(
            phoneName: phoneName,
            phoneApiLevel: 26,
            region: region
        )
        var ccmNonce = Data()
        ccmNonce.append(encryptionNonce)
        ccmNonce.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        guard let encryptedDeviceInfo = XiaomiCrypto.aesCCMEncrypt(key: encryptionKey, nonce: ccmNonce, payload: deviceInfo) else {
            throw TransportError.authRejected("Failed to encrypt the device information.")
        }
        var noncesInput = phoneNonce
        noncesInput.append(watchNonce)
        let encryptedNonces = XiaomiCrypto.hmacSHA256(key: encryptionKey, message: noncesInput)

        // Accept any type-1 reply carrying an auth status so a rejection is
        // surfaced immediately instead of waiting out the full timeout.
        setStage("Confirming encrypted authentication")
        let authGate = mountReply { reply in
            guard reply.type == 1 else { return false }
            return reply.subtype == 27
        }
        try await sendPlainCommand(
            XiaomiProto.buildAuthStep3Command(encryptedNonces: encryptedNonces, encryptedDeviceInfo: encryptedDeviceInfo)
        )

        let authReply = try await authGate.wait()
        let authStatus = authReply.auth?.authStatus
        onDiagnostic?("Authentication response: status=\(authStatus.map(String.init) ?? "absent")")
        if let authStatus, authStatus != 1 {
            throw TransportError.authRejected("The band rejected the auth key.")
        }
        // BLE v2 uses encrypted protobuf commands after the nonce/auth
        // handshake. Only the response to that handshake unlocks installation.
        encryptionGenerated = true
        authenticated = true
    }

    // MARK: - Watchface install

    /// Full install pipeline for a compiled face payload.
    func installWatchface(payload: Data) async throws {
        guard authenticated else {
            throw TransportError.transferFailed("The band is not authenticated.")
        }
        guard let id = XiaomiProto.watchfaceID(from: payload) else {
            throw TransportError.validation(.notCompiled)
        }
        let size = payload.count

        // 1. Tell the band a face is coming.
        setStage("Waiting for watchface install approval (4/4)")
        let installGate = mountReply { $0.type == 4 && $0.subtype == 4 }
        try await sendEncryptedCommand(XiaomiProto.buildWatchfaceInstallCommand(id: id, size: size))
        let installReply = try await installGate.wait()
        log("[install] reply watchfaceStatus=\(installReply.watchfaceStatus.map(String.init) ?? "nil") watchfaceAck=\(installReply.watchfaceAck.map(String.init) ?? "nil")")
        log("[install] reply raw=\(installReply.raw?.hex ?? "nil")")
        if let status = installReply.watchfaceStatus, status != 0 {
            throw TransportError.transferFailed("The band rejected the install (status \(status)).")
        }

        // 2. Negotiate the upload.
        setStage("Waiting for upload parameters (22/0)")
        let md5 = XiaomiCrypto.md5(payload)
        let requestProtobuf = XiaomiProto.buildUploadRequestCommand(type: 16, md5: md5, size: size)
        log("[upload] request pb=\(requestProtobuf.hex) md5=\(md5.hex) size=\(size) id=\(id)")
        let ackGate = mountReply { $0.type == 22 && $0.subtype == 0 }
        try await sendEncryptedCommand(requestProtobuf)
        let ackReply = try await ackGate.wait()
        guard let ack = ackReply.uploadAck else {
            throw TransportError.transferFailed("The band did not acknowledge the upload.")
        }
        log("[upload] ack md5=\(ack.md5?.hex ?? "nil") unknown2=\(ack.unknown2.map(String.init) ?? "nil") resumePosition=\(ack.resumePosition.map(String.init) ?? "nil") chunkSize=\(ack.chunkSize.map(String.init) ?? "nil")")
        log("[upload] ack raw=\(ackReply.raw?.hex ?? "nil")")
        if let unknown2 = ack.unknown2, unknown2 != 0 {
            // The Smart Band 10 Pro firmware answers unknown2 = 1 for an upload it
            // then accepts (confirmed on hardware); only other values reject.
            guard unknown2 == 1 else {
                throw TransportError.transferFailed("The band rejected the upload (\(unknown2)).")
            }
            log("[upload] ack unknown2 = 1 (accepted by this firmware) — proceeding with the DATA channel")
        }
        let chunkSize = ack.chunkSize ?? 2048
        let resumePosition = min(ack.resumePosition ?? 0, size)
        guard chunkSize > 4, chunkSize <= 65_533 else {
            throw TransportError.transferFailed("Invalid upload chunk size: \(chunkSize).")
        }
        // Resuming requires firmware-specific offsets/checksums. Never emit a
        // truncated file with a whole-file size and checksum by guessing.
        guard resumePosition == 0 else {
            throw TransportError.transferFailed("The band requested a partial upload. Reconnect and retry from the beginning.")
        }

        // 3. Stream the payload in DATA-channel parts.
        setStage("Uploading watchface")
        var upload = Data()
        upload.append(0)
        upload.append(UInt8(16)) // TYPE_WATCHFACE
        upload.append(XiaomiCrypto.md5(payload))
        withUnsafeBytes(of: UInt32(size).littleEndian) { upload.append(contentsOf: $0) }
        upload.append(payload.suffix(from: payload.index(payload.startIndex, offsetBy: resumePosition)))

        var crcData = upload
        withUnsafeBytes(of: XiaomiCrypto.crc32(upload).littleEndian) { crcData.append(contentsOf: $0) }
        let payloadBytes = [UInt8](crcData)

        let partSize = max(1, chunkSize - 4)
        let partCount = (payloadBytes.count + partSize - 1) / partSize
        guard partCount > 0 else {
            throw TransportError.transferFailed("The face payload is empty after upload negotiation.")
        }
        guard partCount <= Int(UInt16.max) else {
            throw TransportError.transferFailed("Negotiated chunk size is too small for this file.")
        }

        for part in 0..<partCount {
            let start = part * partSize
            let end = min((part + 1) * partSize, payloadBytes.count)
            var chunk = Data()
            withUnsafeBytes(of: UInt16(partCount).littleEndian) { chunk.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(part + 1).littleEndian) { chunk.append(contentsOf: $0) }
            chunk.append(contentsOf: payloadBytes[start..<end])
            try await sendDataChunk(chunk)
            onProgress?(Double(part + 1) / Double(partCount))
        }

        // 4. Activate and confirm.
        setStage("Activating watchface")
        let activation = mountReply { $0.type == 4 && $0.subtype == 1 }
        try await sendEncryptedCommand(XiaomiProto.buildSetWatchfaceCommand(id: id))
        let activated = try await activation.wait()
        if let status = activated.status, status != 0 {
            throw TransportError.transferFailed("Activation rejected (status \(status)).")
        }
        try await sendEncryptedCommand(XiaomiProto.buildWatchfaceListCommand())
    }

    // MARK: - Auth key derivation

    /// `computeAuthStep3Hmac` from Gadgetbridge — 64 bytes split into
    /// decryption/encryption keys + 4-byte nonces.
    static func computeAuthStep3Hmac(secret: Data, phoneNonce: Data, watchNonce: Data) -> Data {
        let label = Data("miwear-auth".utf8)
        var combined = phoneNonce
        combined.append(watchNonce)
        let hmacKey = XiaomiCrypto.hmacSHA256(key: combined, message: secret)

        var output = Data()
        output.reserveCapacity(64)
        var intermediate = Data()
        var counter: UInt8 = 1
        while output.count < 64 {
            var input = intermediate
            input.append(label)
            input.append(counter)
            intermediate = XiaomiCrypto.hmacSHA256(key: hmacKey, message: input)
            output.append(intermediate)
            counter &+= 1
        }
        return output.prefix(64)
    }

    private static func hexKey(_ authKey: String) throws -> Data {
        let clean = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = clean.hasPrefix("0x") ? String(clean.dropFirst(2)) : clean
        guard hex.count == 32, let bytes = Data(hexString: hex) else {
            throw TransportError.authKeyMalformed
        }
        return bytes
    }
}

/// Serializes complete frames, including every ATT fragment and ACK. Actor
/// isolation alone is insufficient: an async write yields between fragments.
@MainActor
final class XiaomiFrameWriter {
    private var tail: Task<Void, Error>?
    private var failure: Error?

    func fail(_ error: Error) { failure = error }

    func enqueue(_ frame: Data, using writer: @escaping (Data) async throws -> Void) -> Task<Void, Error> {
        let previous = tail
        let task = Task { @MainActor in
            if let previous { try await previous.value }
            if let failure = self.failure { throw failure }
            try Task.checkCancellation()
            try await writer(frame)
        }
        tail = task
        return task
    }
}

private extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private func log(_ message: String) {
    print("[xiaomi] \(message)")
}
