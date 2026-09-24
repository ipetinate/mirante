import Foundation
import CommonCrypto
import CryptoKit

/// Cryptographic primitives ported 1:1 from Gadgetbridge's Xiaomi auth stack
/// (`XiaomiAuthService.java`, `XiaomiSppPacketV2.java`, `CheckSums.java`), so a
/// phone running Mirante performs a byte-identical handshake with the band.
enum XiaomiCrypto {
    // MARK: - AES-ECB (used as the building block for CTR and CCM)

    /// Raw AES-128 ECB, no padding. Input length must be an exact multiple of 16.
    static func aesECB(_ key: Data, _ data: Data) -> Data? {
        guard key.count == 16 else { return nil }
        var out = Data(count: data.count)
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count,
                        nil,
                        inPtr.baseAddress, data.count,
                        outPtr.baseAddress, outCount,
                        nil
                    )
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    // MARK: - AES-CTR (used for v2 encrypted channel, key used as IV)

    /// AES-128 in counter mode, mirroring the Java `AES/CTR/NoPadding` cipher:
    /// the keystream is `E(IV+0), E(IV+1), ...` where the 16-byte IV block is
    /// incremented as a big-endian 128-bit integer between blocks.
    static func aesCTR(_ key: Data, _ iv: Data, _ data: Data) -> Data? {
        guard key.count == 16, iv.count == 16 else { return nil }
        var counter = [UInt8](iv)
        var out = Data()
        out.reserveCapacity(data.count)
        var offset = 0
        while offset < data.count {
            guard let stream = aesECB(key, Data(counter)) else { return nil }
            let count = min(16, data.count - offset)
            for i in 0..<count {
                out.append(data[data.startIndex + offset + i] ^ stream[stream.startIndex + i])
            }
            increment(&counter)
            offset += count
        }
        return out
    }

    /// CCM per RFC 3610 with the parameters the band uses: 12-byte nonce,
    /// 4-byte authentication tag, no associated data. `Burdette`: L = 3,
    /// so the length field is 3 bytes and the message must stay below 16 MiB.
    /// Returns `ciphertext || tag`.
    static func aesCCMEncrypt(key: Data, nonce: Data, payload: Data) -> Data? {
        guard key.count == 16, nonce.count == 12 else { return nil }
        let m = 4 // tag bytes (mac size 32 bits)
        let l = 15 - nonce.count // = 3
        let flagsB0 = (UInt8(m - 2) << 3) | UInt8(l - 1) // no adata => 0x0A
        let flagsA0 = UInt8(l - 1) // 0x02

        // B0 = flags || nonce || message length (3-byte big-endian)
        var b0 = [UInt8]()
        b0.append(flagsB0)
        b0.append(contentsOf: nonce)
        let lenLo = UInt32(payload.count)
        for shift in stride(from: (l - 1) * 8, through: 0, by: -8) {
            b0.append(UInt8((lenLo >> UInt32(shift)) & 0xFF))
        }

        // CBC-MAC over B0 || payload (zero padded to block size)
        var blocks = [b0]
        var buf = [UInt8](payload)
        while buf.count % 16 != 0 { buf.append(0) }
        for i in stride(from: 0, to: buf.count, by: 16) {
            blocks.append(Array(buf[i..<i + 16]))
        }
        guard var mac = aesECB(key, Data(blocks[0])) else { return nil }
        for i in 1..<blocks.count {
            var block = [UInt8](mac)
            for j in 0..<16 { block[j] ^= blocks[i][j] }
            guard let next = aesECB(key, Data(block)) else { return nil }
            mac = next
        }
        let tag = Array(mac[0..<m])

        // Keystream blocks S0 (tag mask), S1, S2, ...; ciphertext XORs S1 onward.
        func streamBlock(_ counter: UInt32) -> Data? {
            var a = [UInt8]()
            a.append(flagsA0)
            a.append(contentsOf: nonce)
            for shift in stride(from: (l - 1) * 8, through: 0, by: -8) {
                a.append(UInt8((counter >> UInt32(shift)) & 0xFF))
            }
            return aesECB(key, Data(a))
        }

        guard let s0 = streamBlock(0) else { return nil }
        let s0Bytes = [UInt8](s0)

        var cipher = Data()
        cipher.reserveCapacity(payload.count)
        let inBytes = [UInt8](payload)
        var blockIndex: UInt32 = 1
        var offset = 0
        while offset < payload.count {
            guard var stream = streamBlock(blockIndex) else { return nil }
            let count = min(16, payload.count - offset)
            for i in 0..<count {
                cipher.append(inBytes[offset + i] ^ stream[i])
            }
            blockIndex += 1
            offset += count
        }

        // CCM tag encryption: XOR the tag with the first m bytes of S0.
        let masked = (0..<m).map { s0Bytes[$0] ^ tag[$0] }
        var result = cipher
        result.append(contentsOf: masked)
        return result
    }

    // MARK: - HMAC-SHA256

    static func hmacSHA256(key: Data, message: Data) -> Data {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            message.withUnsafeBytes { messagePtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyPtr.baseAddress, key.count, messagePtr.baseAddress, message.count, &out)
            }
        }
        return Data(out)
    }

    // MARK: - Digests / checksums

    static func md5(_ data: Data) -> Data {
        let digest = Insecure.MD5.hash(data: data)
        return Data(digest)
    }

    /// Standard CRC-32 (IEEE 802.3, polynomial 0xEDB88320, init 0xFFFFFFFF).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB88320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }

    /// CRC-16/ARC, reflected, poly 0x8005, init 0, xorout 0 — the exact bit
    /// algorithm from `XiaomiSppPacketV2.calculatePayloadChecksum`.
    static func crc16ARC(_ data: Data) -> UInt16 {
        var crc: UInt32 = 0
        for byte in data {
            for j in 0..<8 {
                crc <<= 1
                if (((crc >> 16) & 1) ^ (UInt32(byte) >> j) & 1) == 1 {
                    crc ^= 0x8005
                }
            }
        }
        let reversed = reverseBits32(crc)
        return UInt16((reversed >> 16) & 0xFFFF)
    }

    // MARK: - Private helpers

    private static func reverseBits32(_ value: UInt32) -> UInt32 {
        var x = value
        var result: UInt32 = 0
        for _ in 0..<32 {
            result = (result << 1) | (x & 1)
            x >>= 1
        }
        return result
    }

    private static func increment(_ counter: inout [UInt8]) {
        for i in counter.indices.reversed() {
            counter[i] &+= 1
            if counter[i] != 0 { break }
        }
    }
}