import Foundation

/// The byte-level frame shared by the classic SPP and BLE v2 variants of the
/// Xiaomi protocol (port of `XiaomiSppPacketV2.java`).
enum XiaomiSppPacketV2 {
    static let preamble: [UInt8] = [0xA5, 0xA5]

    enum PacketType: Int {
        case ack = 1
        case sessionConfig = 2
        case data = 3
    }

    /// Raw channel ids carried in the first payload byte of a DATA packet.
    enum Channel: Int {
        case protobuf = 1
        case data = 2
        case activity = 5
    }

    enum OpCode: Int {
        case sendPlaintext = 1
        case sendEncrypted = 2
    }

    struct Packet {
        let type: PacketType?
        let sequence: Int
        let payload: Data
    }

    // MARK: - Encode

    static func encode(type: Int, sequence: Int, payload: Data) -> Data {
        var out = Data()
        out.reserveCapacity(8 + payload.count)
        out.append(contentsOf: preamble)
        out.append(UInt8(type & 0x0F))                 // flags + packet type (low nibble)
        out.append(UInt8(sequence & 0xFF))             // sequence number
        withUnsafeBytes(of: UInt16(payload.count).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: XiaomiCrypto.crc16ARC(payload).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Session config START request — payload bytes identical to the reference
    /// packet dump shipped in Gadgetbridge (`SessionConfigPacket`).
    static func encodeSessionStartRequest() -> Data {
        var payload = Data()
        payload.append(UInt8(1)) // opcode START_SESSION_REQUEST
        // TLV: key(1) version 01.00.00
        payload.append(contentsOf: [UInt8(1), 0x03, 0x00, 0x01, 0x00, 0x00])
        // TLV: key(2) MAX_FRAME_SIZE = 0xFC00
        payload.append(contentsOf: [UInt8(2), 0x02, 0x00, 0x00, 0xFC])
        // TLV: key(3) TX_WIN = 32
        payload.append(contentsOf: [UInt8(3), 0x02, 0x00, 0x20, 0x00])
        // TLV: key(4) SEND_TIMEOUT = 10000ms
        payload.append(contentsOf: [UInt8(4), 0x02, 0x00, 0x10, 0x27])
        return encode(type: PacketType.sessionConfig.rawValue, sequence: 0, payload: payload)
    }

    /// Ack packet for a received DATA packet.
    static func encodeAck(sequence: Int) -> Data {
        encode(type: PacketType.ack.rawValue, sequence: sequence, payload: Data())
    }

    /// DATA packet carrying an inner channel payload (`[channel][opcode] body`).
    static func encodeData(sequence: Int, channel: Channel, opcode: OpCode, body: Data, encryptor: @escaping (Data) -> Data) -> Data {
        var payload = Data()
        payload.append(UInt8(channel.rawValue & 0x0F))
        payload.append(UInt8(opcode.rawValue & 0xFF))
        if opcode == .sendEncrypted {
            payload.append(encryptor(body))
        } else {
            payload.append(body)
        }
        return encode(type: PacketType.data.rawValue, sequence: sequence, payload: payload)
    }

    // MARK: - Decode

    /// Consumes exactly one packet from `data` when a full one is present.
    struct ParseResult {
        let packet: Packet?
        let consumed: Int
    }

    static func parse(_ data: Data) -> ParseResult {
        guard data.count >= 8 else { return ParseResult(packet: nil, consumed: 0) }
        let bytes = [UInt8](data)
        guard bytes[0] == preamble[0], bytes[1] == preamble[1] else {
            // stray bytes ahead of the next preamble — skip to it
            if let next = bytes.dropFirst(1).firstIndex(of: preamble[0]) {
                return ParseResult(packet: nil, consumed: next)
            }
            return ParseResult(packet: nil, consumed: data.count)
        }
        let typeByte = bytes[2] & 0x0F
        let sequence = Int(bytes[3])
        let payloadLength = Int(UInt16(bytes[4]) | (UInt16(bytes[5]) << 8))
        let givenChecksum = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        let total = 8 + payloadLength
        guard data.count >= total else { return ParseResult(packet: nil, consumed: 0) } // incomplete
        let payload = data.subdata(in: data.startIndex + 8 ..< data.startIndex + total)
        guard XiaomiCrypto.crc16ARC(payload) == givenChecksum else {
            return ParseResult(packet: nil, consumed: total) // corrupt — drop frame
        }
        return ParseResult(
            packet: Packet(type: PacketType(rawValue: Int(typeByte)), sequence: sequence, payload: payload),
            consumed: total
        )
    }
}