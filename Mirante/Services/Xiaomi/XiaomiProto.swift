import Foundation

/// Minimal proto2 encoder/decoder covering exactly the Xiaomi messages Mirante
/// speaks with the band. Field numbers and message shapes are taken verbatim
/// from Gadgetbridge's `xiaomi.proto`; the wire format is standard protobuf.
enum XiaomiProto {

    // MARK: - Writer

    struct Writer {
        private(set) var data = Data()

        mutating func varint(_ value: UInt64) {
            var v = value
            while v >= 0x80 {
                data.append(UInt8(v & 0x7F) | 0x80)
                v >>= 7
            }
            data.append(UInt8(v))
        }

        mutating func tag(_ field: Int, _ wire: Int) {
            varint(UInt64(field << 3 | wire))
        }

        mutating func field(_ number: Int, _ value: UInt32) {
            tag(number, 0)
            varint(UInt64(value))
        }

        mutating func field(_ number: Int, _ value: UInt64) {
            tag(number, 0)
            varint(value)
        }

        mutating func field(_ number: Int, bytes: Data) {
            tag(number, 2)
            varint(UInt64(bytes.count))
            data.append(bytes)
        }

        mutating func field(_ number: Int, string: String) {
            field(number, bytes: Data(string.utf8))
        }

        mutating func field(_ number: Int, float: Float) {
            tag(number, 5)
            var bits = float.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
    }

    // MARK: - Reader

    struct Field {
        let number: Int
        let wire: Int
        let data: Data
    }

    static func parse(_ data: Data) -> [Field] {
        var fields: [Field] = []
        var index = data.startIndex
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex {
                let byte = data[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }
        while index < data.endIndex {
            guard let key = readVarint() else { return fields }
            let number = Int(key >> 3)
            let wire = Int(key & 0x7)
            switch wire {
            case 0:
                guard let v = readVarint() else { return fields }
                fields.append(Field(number: number, wire: wire, data: varintData(v)))
            case 1:
                let count = min(8, data.endIndex - index)
                fields.append(Field(number: number, wire: wire, data: data.subdata(in: index ..< index + count)))
                index += count
            case 2:
                guard let len = readVarint(), len <= data.endIndex - index else { return fields }
                let count = Int(len)
                fields.append(Field(number: number, wire: wire, data: data.subdata(in: index ..< index + count)))
                index += count
            case 5:
                let count = min(4, data.endIndex - index)
                fields.append(Field(number: number, wire: wire, data: data.subdata(in: index ..< index + count)))
                index += count
            default:
                return fields
            }
        }
        return fields
    }

    private static func varintData(_ value: UInt64) -> Data {
        var writer = Writer()
        writer.varint(value)
        return writer.data
    }

    static func readVarint(_ data: Data) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for byte in data {
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func readUInt32(_ data: Data) -> UInt32? {
        guard let v = readVarint(data) else { return nil }
        return UInt32(truncatingIfNeeded: v)
    }

    static func readString(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }

    // MARK: - Command envelope

    struct CommandInfo {
        var type: Int?
        var subtype: Int?
        var status: Int?
        var auth: AuthInfo?
        var watchfaceStatus: Int?
        var watchfaceAck: Int?
        var uploadAck: UploadAck?
        /// True when the incoming frame was a session-config packet rather than
        /// a protobuf command.
        var isSessionConfig = false
        /// Raw decrypted protobuf bytes of the command, when known (diagnostics).
        var raw: Data?
    }

    struct AuthInfo {
        var watchNonce: Data?
        var watchHmac: Data?
        var authStatus: Int?
    }

    struct UploadAck {
        var md5: Data?
        var unknown2: Int?
        var resumePosition: Int?
        var chunkSize: Int?
    }

    static func parseCommand(_ data: Data) -> CommandInfo? {
        var info = CommandInfo()
        for field in parse(data) {
            switch field.number {
            case 1: info.type = Int(readUInt32(field.data) ?? 0)
            case 2: info.subtype = Int(readUInt32(field.data) ?? 0)
            case 3: info.auth = parseAuth(field.data)
            case 6: parseWatchface(field.data, into: &info)
            case 24: parseUpload(field.data, into: &info)
            case 100: info.status = Int(readUInt32(field.data) ?? 0)
            default: break
            }
        }
        return info
    }

    private static func parseAuth(_ data: Data) -> AuthInfo? {
        var info = AuthInfo()
        for field in parse(data) {
            switch field.number {
            case 8: info.authStatus = Int(readUInt32(field.data) ?? 0)
            case 31:
                for sub in parse(field.data) {
                    switch sub.number {
                    case 1: info.watchNonce = sub.data
                    case 2: info.watchHmac = sub.data
                    default: break
                    }
                }
            default: break
            }
        }
        return info
    }

    private static func parseWatchface(_ data: Data, into info: inout CommandInfo) {
        for field in parse(data) {
            switch field.number {
            case 4: info.watchfaceAck = Int(readUInt32(field.data) ?? 0)
            case 5: info.watchfaceStatus = Int(readUInt32(field.data) ?? 0)
            default: break
            }
        }
    }

    private static func parseUpload(_ data: Data, into info: inout CommandInfo) {
        for field in parse(data) {
            guard field.number == 2 else { continue }
            var ack = UploadAck()
            for sub in parse(field.data) {
                switch sub.number {
                case 1: ack.md5 = sub.data
                case 2: ack.unknown2 = Int(readUInt32(sub.data) ?? 0)
                case 4: ack.resumePosition = Int(readUInt32(sub.data) ?? 0)
                case 5: ack.chunkSize = Int(readUInt32(sub.data) ?? 0)
                default: break
                }
            }
            info.uploadAck = ack
        }
    }

    // MARK: - Command builders

    /// Auth step 1: `Command(type=1, subtype=26, auth.phoneNonce{nonce})`.
    static func buildNonceCommand(nonce: Data) -> Data {
        var phoneNonce = Writer()
        phoneNonce.field(1, bytes: nonce)
        var auth = Writer()
        auth.field(30, bytes: phoneNonce.data)
        var writer = Writer()
        writer.field(1, UInt32(1))          // type = COMMAND_TYPE
        writer.field(2, UInt32(26))         // subtype = CMD_NONCE
        writer.field(3, bytes: auth.data)   // auth
        return writer.data
    }

    /// Auth step 3: `Command(type=1, subtype=27, auth.authStep3{...})`.
    static func buildAuthStep3Command(encryptedNonces: Data, encryptedDeviceInfo: Data) -> Data {
        var step3 = Writer()
        step3.field(1, bytes: encryptedNonces)
        step3.field(2, bytes: encryptedDeviceInfo)
        var auth = Writer()
        auth.field(32, bytes: step3.data)   // auth.authStep3
        var writer = Writer()
        writer.field(1, UInt32(1))          // type = COMMAND_TYPE
        writer.field(2, UInt32(27))         // subtype = CMD_AUTH
        writer.field(3, bytes: auth.data)   // auth
        return writer.data
    }

    /// `AuthDeviceInfo` message serialized on its own (then CCM-encrypted).
    static func buildAuthDeviceInfo(phoneName: String, phoneApiLevel: Float, region: String) -> Data {
        var writer = Writer()
        writer.field(1, UInt32(0))          // unknown1 = 0
        writer.field(2, float: phoneApiLevel)
        writer.field(3, string: phoneName)
        writer.field(4, UInt32(224))        // unknown3 = 224
        writer.field(5, string: region)
        return writer.data
    }

    /// `Command(type=4, subtype=4, watchface.watchfaceInstallStart{id,size})`.
    static func buildWatchfaceInstallCommand(id: String, size: Int) -> Data {
        var start = Writer()
        start.field(1, string: id)
        start.field(2, UInt32(size))
        var watchface = Writer()
        watchface.field(6, bytes: start.data)
        var writer = Writer()
        writer.field(1, UInt32(4))          // type = COMMAND_TYPE (watchface)
        writer.field(2, UInt32(4))          // subtype = CMD_WATCHFACE_INSTALL
        writer.field(6, bytes: watchface.data)
        return writer.data
    }

    /// `Command(type=22, subtype=0, dataUpload.dataUploadRequest{type,md5,size})`.
    static func buildUploadRequestCommand(type: UInt32, md5: Data, size: Int) -> Data {
        var request = Writer()
        request.field(1, type)
        request.field(2, bytes: md5)
        request.field(3, UInt32(size))
        var upload = Writer()
        upload.field(1, bytes: request.data)
        var writer = Writer()
        writer.field(1, UInt32(22))         // type = COMMAND_TYPE (data upload)
        writer.field(2, UInt32(0))          // subtype = CMD_UPLOAD_START
        writer.field(24, bytes: upload.data)
        return writer.data
    }

    /// `Command(type=4, subtype=1, watchface.watchfaceId{id})` — activate face.
    static func buildSetWatchfaceCommand(id: String) -> Data {
        var watchface = Writer()
        watchface.field(2, string: id)      // watchface.watchfaceId
        var writer = Writer()
        writer.field(1, UInt32(4))          // type = COMMAND_TYPE (watchface)
        writer.field(2, UInt32(1))          // subtype = CMD_WATCHFACE_SET
        writer.field(6, bytes: watchface.data)
        return writer.data
    }

    /// `Command(type=4, subtype=0)` — request the installed watchface list.
    static func buildWatchfaceListCommand() -> Data {
        var writer = Writer()
        writer.field(1, UInt32(4))
        writer.field(2, UInt32(0))
        return writer.data
    }

    // MARK: - Watchface id extraction

    /// The numeric face id lives as a NUL-terminated ASCII string at offset
    /// 0x28 of the compiled `.bin` (Gadgetbridge `XiaomiFWHelper.parseAsWatchface`).
    static func watchfaceID(from payload: Data) -> String? {
        guard payload.count >= 0x30 else { return nil }
        var bytes: [UInt8] = []
        for byte in payload.suffix(from: payload.index(payload.startIndex, offsetBy: 0x28)) {
            if byte == 0 { break }
            bytes.append(byte)
        }
        guard !bytes.isEmpty, let id = String(bytes: bytes, encoding: .ascii), !id.isEmpty else { return nil }
        guard id.allSatisfy(\.isNumber) else { return nil }
        return id
    }
}