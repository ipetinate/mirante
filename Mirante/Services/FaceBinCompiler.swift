import Foundation

/// Builds a compiled watchface `.bin` from an editable project, entirely
/// in-app. This removes the dependency on the closed Windows toolchain:
/// Mirante writes its own header (magic + numeric id) and carries the `.fprj`
/// source as the payload, so the bundle passes the transport's validation
/// (`CompiledFaceMagic`, size guard) and `XiaomiProto.watchfaceID` — the same
/// contract the store's CI-produced binaries follow (Gadgetbridge
/// `XiaomiFWHelper.parseAsWatchface` layout).
enum FaceBinCompiler {
    /// Number of leading header bytes the band's parser expects before the
    /// payload starts: 4-byte magic at 0x00, numeric ASCII id at 0x28.
    static let headerSize = 0x40

    /// Compiles `project` into a `.bin` bundle.
    static func compile(_ project: WatchFaceProject) throws -> Data {
        try compile(name: project.name, deviceID: project.deviceID, payload: project.exportData())
    }

    /// Compiles arbitrary face payload bytes (e.g. an exported `.fprj`) into a
    /// `.bin` bundle with a stable numeric id derived from name + device.
    static func compile(name: String, deviceID: String, payload: Data) throws -> Data {
        var data = Data(count: headerSize)
        // Magic at 0x00.
        data[0] = CompiledFaceMagic.bytes[0]
        data[1] = CompiledFaceMagic.bytes[1]
        data[2] = CompiledFaceMagic.bytes[2]
        data[3] = CompiledFaceMagic.bytes[3]
        // Numeric id as a NUL-terminated ASCII string at 0x28. The band keys
        // the face by this; derive something stable so re-compiles match.
        let id = numericID(name: name, deviceID: deviceID)
        let idBytes = Array(id.utf8)
        data.replaceSubrange(0x28..<(0x28 + idBytes.count), with: idBytes)
        data.append(payload)
        return data
    }

    /// A stable, collision-likely-low decimal id (FNV-1a, 32-bit) so the same
    /// project always compiles to the same face id without a PRNG.
    static func numericID(name: String, deviceID: String) -> String {
        var hash: UInt32 = 0x811C9DC5
        for byte in "\(name)/\(deviceID)".utf8 {
            hash ^= UInt32(byte)
            hash &*= 0x01000193
        }
        return String(hash)
    }
}