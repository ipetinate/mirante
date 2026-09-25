import Foundation

/// Errors raised while assembling or inspecting an o66 watchface binary.
enum O66CompilerError: Error, LocalizedError {
    case invalidData(String)
    case invalidID
    case missingImage(String)
    case structural(String)

    var errorDescription: String? {
        switch self {
        case .invalidData(let message): return "Invalid o66 data: \(message)"
        case .invalidID: return "o66 package IDs must contain exactly 9 digits."
        case .missingImage(let name): return "Could not resolve image \"\(name)\"."
        case .structural(let message): return "Package failed structural inspection: \(message)"
        }
    }
}

/// Little-endian readers/writers mirroring the toolkit's `parser/bytes.ts`.
enum O66Bytes {
    static func readU16LE(_ data: [UInt8], _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    static func readI16LE(_ data: [UInt8], _ offset: Int) -> Int {
        let value = readU16LE(data, offset)
        return value >= 0x8000 ? value - 0x10000 : value
    }

    static func readU24LE(_ data: [UInt8], _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16)
    }

    static func readU32LE(_ data: [UInt8], _ offset: Int) -> Int {
        Int(data[offset])
            | (Int(data[offset + 1]) << 8)
            | (Int(data[offset + 2]) << 16)
            | (Int(data[offset + 3]) << 24)
    }

    static func writeU16LE(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
        buffer[offset] = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    static func writeU24LE(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
        buffer[offset] = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
        buffer[offset + 2] = UInt8((value >> 16) & 0xff)
    }

    static func writeU32LE(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
        buffer[offset] = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
        buffer[offset + 2] = UInt8((value >> 16) & 0xff)
        buffer[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    static func writeFixedString(_ buffer: inout [UInt8], _ offset: Int, _ maxLength: Int, _ value: String) {
        let bytes = Array(value.utf8)
        for index in 0..<maxLength {
            buffer[offset + index] = index < bytes.count ? bytes[index] : 0
        }
    }

    static func toHex(_ data: [UInt8]) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}