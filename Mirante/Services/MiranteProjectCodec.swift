import Foundation

/// Native, lossless project interchange for Mirante.
enum MiranteProjectCodec {
    static let formatVersion = 1

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let project: WatchFaceProject
    }

    static func encode(_ project: WatchFaceProject) throws -> Data {
        let envelope = Envelope(format: "mirante", version: formatVersion, project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> WatchFaceProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.format == "mirante" else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Not a Mirante project."])
        }
        guard envelope.version <= formatVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This project was created by a newer Mirante version."])
        }
        return envelope.project
    }
}

extension WatchFaceProject {
    func exportMiranteData() -> Data? { try? MiranteProjectCodec.encode(self) }
}
