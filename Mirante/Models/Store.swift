import Foundation

/// Publisher-facing configuration for the GitHub-backed watchface store.
/// The owner/repository/branch name the store lives at, plus the handle and
/// display name faces are published under. The GitHub token is stored
/// separately (Keychain), never inside this codable value.
struct StoreConfig: Codable, Hashable {
    var owner: String
    var repository: String
    var branch: String
    var publisherHandle: String
    var publisherName: String

    static let defaultRepository = "mirante-store"
    static let defaultBranch = "main"

    /// The app's only store. No setup — this is what every screen uses.
    static let standard = StoreConfig(
        owner: "ipetinate",
        repository: defaultRepository,
        branch: defaultBranch,
        publisherHandle: "ipetinate",
        publisherName: "ipetinate"
    )

    var isConfigured: Bool {
        !owner.isEmpty && !repository.isEmpty && !branch.isEmpty && !publisherHandle.isEmpty
    }
}

/// A store author. Right now every face is published by the app user through
/// the same config; this keeps the door open for multi-publisher stores later.
struct StoreAuthor: Codable, Hashable {
    var handle: String
    var name: String
}

/// One watchface published to the store, as recorded in `index.json`.
struct StoreFace: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var description: String
    var deviceID: String
    var tags: [String]
    var version: String
    var updatedAt: Date
    var author: StoreAuthor
    /// False until the store's CI has compiled `face.bin` from `face.fprj`.
    var compiled: Bool
    /// Size of the compiled binary in bytes, when `compiled` is true.
    var binarySize: Int?
    /// Relative paths inside the store repository.
    var sourcePath: String
    var binaryPath: String?
    var previewPath: String?

    var device: Device? { Device.find(deviceID) }

    /// The directory inside the repo this face lives in, e.g.
    /// `faces/<handle>/<slug>/`.
    var directory: String {
        sourcePath.components(separatedBy: "/").dropLast().joined(separator: "/")
    }

    init(
        id: String,
        name: String,
        description: String,
        deviceID: String,
        tags: [String],
        version: String,
        updatedAt: Date,
        author: StoreAuthor,
        compiled: Bool,
        binarySize: Int?,
        sourcePath: String,
        binaryPath: String?,
        previewPath: String?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.deviceID = deviceID
        self.tags = tags
        self.version = version
        self.updatedAt = updatedAt
        self.author = author
        self.compiled = compiled
        self.binarySize = binarySize
        self.sourcePath = sourcePath
        self.binaryPath = binaryPath
        self.previewPath = previewPath
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, deviceID, tags, version, updatedAt, author, compiled, binarySize
        case sourcePath, binaryPath, previewPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        deviceID = try c.decode(String.self, forKey: .deviceID)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        author = try c.decodeIfPresent(StoreAuthor.self, forKey: .author)
            ?? StoreAuthor(handle: c.decodeIfPresent(String.self, forKey: .id) ?? "unknown", name: "")
        compiled = try c.decodeIfPresent(Bool.self, forKey: .compiled) ?? false
        binarySize = try c.decodeIfPresent(Int.self, forKey: .binarySize)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        binaryPath = try c.decodeIfPresent(String.self, forKey: .binaryPath)
        previewPath = try c.decodeIfPresent(String.self, forKey: .previewPath)
    }
}

/// The store root document, `index.json`.
struct StoreManifest: Codable, Hashable {
    var schemaVersion: Int
    var generatedAt: Date
    var publisher: StoreAuthor?
    var faces: [StoreFace]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, publisher, faces
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        publisher = try c.decodeIfPresent(StoreAuthor.self, forKey: .publisher)
        faces = try c.decodeIfPresent([StoreFace].self, forKey: .faces) ?? []
    }

    init(schemaVersion: Int, generatedAt: Date, publisher: StoreAuthor?, faces: [StoreFace]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.publisher = publisher
        self.faces = faces
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encodeIfPresent(publisher, forKey: .publisher)
        try c.encode(faces, forKey: .faces)
    }
}

/// Shared JSON codec for store documents. `updatedAt` and `generatedAt` are
/// ISO8601 so the manifest is readable by GitHub's UI and the CI workflow.
enum StoreJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}