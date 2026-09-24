import CoreGraphics
import Foundation

struct WatchFaceProject: Hashable {
    var name: String
    var deviceID: String
    var format: ProjectFormat = .fprj
    var widgets: [WidgetItem] = []
    var aodWidgets: [WidgetItem] = []
    var usesAOD: Bool = false
    var updatedAt = Date()
    /// Image data per image / image-list widget, keyed by the widget's UUID
    /// string. Persisted alongside the JSON so imported images survive
    /// relaunches and render in Explore previews.
    var images: [String: Data] = [:]

    var device: Device { Device.find(deviceID) ?? Device.all[0] }

    var screenSize: CGSize {
        CGSize(width: device.width, height: device.height)
    }

    mutating func touch() { updatedAt = Date() }

    /// Indexes `images` by widget id for direct lookups.
    func imageData(for widgetID: UUID) -> Data? {
        images[widgetID.uuidString]
    }
}

extension WatchFaceProject: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, deviceID, format, widgets, aodWidgets, usesAOD, updatedAt, images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        format = try c.decodeIfPresent(ProjectFormat.self, forKey: .format) ?? .fprj
        widgets = try c.decodeIfPresent([WidgetItem].self, forKey: .widgets) ?? []
        aodWidgets = try c.decodeIfPresent([WidgetItem].self, forKey: .aodWidgets) ?? []
        usesAOD = try c.decodeIfPresent(Bool.self, forKey: .usesAOD) ?? false
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        images = try c.decodeIfPresent([String: Data].self, forKey: .images) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(format, forKey: .format)
        try c.encode(widgets, forKey: .widgets)
        try c.encode(aodWidgets, forKey: .aodWidgets)
        try c.encode(usesAOD, forKey: .usesAOD)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(images, forKey: .images)
    }
}

enum ProjectFormat: String, CaseIterable, Identifiable, Codable {
    case fprj
    case gmf

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fprj: return "FPRJ (EasyFace)"
        case .gmf: return "GMF"
        }
    }
    var fileExtension: String { rawValue }
}

extension WatchFaceProject {
    static func new(name: String, device: Device) -> WatchFaceProject {
        WatchFaceProject(name: name, deviceID: device.id)
    }
}

/// A lightweight record of an autosaved project, shown on the welcome screen.
struct RecentProject: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var deviceID: String
    var format: ProjectFormat = .fprj
    var updatedAt: Date
    var fileURL: URL
    /// True when the project was imported from a .fprj file; nil for legacy
    /// entries or faces created in Mirante. Shown in Explore.
    var isImported: Bool? = nil

    var device: Device { Device.find(deviceID) ?? Device.all[0] }
}

/// Autosaves projects as JSON in Application Support and keeps a short
/// history of the most recently worked-on faces.
enum RecentsStore {
    static let maxCount = 8

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Mirante/Recents", isDirectory: true)
    }

    static var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    static func load() -> [RecentProject] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([RecentProject].self, from: data) else { return [] }
        return list.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    /// Saves the current state of a project and returns the history record.
    /// Re-saving a project keeps its existing file so the history stays clean.
    /// Pass `isImported` to tag a disk-imported face; pass nil to keep the
    /// existing record's tag untouched on later autosaves.
    @discardableResult
    static func save(project: WatchFaceProject, isImported: Bool? = nil) -> RecentProject {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(project) else {
            return RecentProject(
                name: project.name,
                deviceID: project.deviceID,
                format: project.format,
                updatedAt: project.updatedAt,
                fileURL: indexURL,
                isImported: isImported
            )
        }

        var list = load()
        let recent: RecentProject
        if let index = list.firstIndex(where: { $0.name == project.name && $0.deviceID == project.deviceID }) {
            list[index].updatedAt = project.updatedAt
            list[index].format = project.format
            if let isImported { list[index].isImported = isImported }
            try? data.write(to: list[index].fileURL)
            recent = list[index]
            list.remove(at: index)
        } else {
            let fileURL = directory.appendingPathComponent("\(sanitized(project.name))-\(UUID().uuidString.prefix(8)).json")
            try? data.write(to: fileURL)
            recent = RecentProject(
                name: project.name,
                deviceID: project.deviceID,
                format: project.format,
                updatedAt: project.updatedAt,
                fileURL: fileURL,
                isImported: isImported ?? false
            )
        }

        list.insert(recent, at: 0)
        if list.count > maxCount {
            for old in list.suffix(from: maxCount) {
                try? FileManager.default.removeItem(at: old.fileURL)
            }
            list = Array(list.prefix(maxCount))
        }
        if let encoded = try? JSONEncoder().encode(list) {
            try? encoded.write(to: indexURL)
        }
        return recent
    }

    static func content(of recent: RecentProject) -> WatchFaceProject? {
        guard let data = try? Data(contentsOf: recent.fileURL) else { return nil }
        return try? JSONDecoder().decode(WatchFaceProject.self, from: data)
    }

    private static func sanitized(_ name: String) -> String {
        let allowed = name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        return allowed.isEmpty ? "project" : allowed
    }
}

/// A compiled watchface (.bin / .face) imported to be viewed and installed on
/// a band. Unlike `RecentProject`, it carries the final binary that the app
/// cannot edit — Mirante only previews its metadata and hands it to the BLE
/// installer.
struct CompiledFace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var fileExtension: String
    var sizeBytes: Int
    var addedAt: Date
    /// Only the file name is persisted: the app's data container can be
    /// reassigned between launches (e.g. a reinstall), which would invalidate
    /// any absolute path. `fileURL` re-resolves against the current directory.
    private var fileName: String

    var isFaceFile: Bool { fileExtension == "face" }

    var fileURL: URL {
        CompiledFacesStore.directory.appendingPathComponent(fileName)
    }

    init(name: String, fileExtension: String, sizeBytes: Int, addedAt: Date, fileURL: URL) {
        self.id = UUID()
        self.name = name
        self.fileExtension = fileExtension
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
        self.fileName = fileURL.lastPathComponent
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, fileExtension, sizeBytes, addedAt, fileName, fileURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        fileExtension = try container.decodeIfPresent(String.self, forKey: .fileExtension) ?? ""
        sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .distantPast
        if let file = try container.decodeIfPresent(String.self, forKey: .fileName) {
            fileName = file
        } else if let urlString = try container.decodeIfPresent(String.self, forKey: .fileURL) {
            fileName = URL(string: urlString)?.lastPathComponent ?? urlString
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .fileName,
                in: container,
                debugDescription: "CompiledFace record is missing a file reference."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(fileName, forKey: .fileName)
    }
}

/// Stores compiled watchface binaries in Application Support so they survive
/// relaunches and can be sent to a band without re-importing.
enum CompiledFacesStore {
    static let maxCount = 12

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Mirante/CompiledFaces", isDirectory: true)
    }

    static var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    static func load() -> [CompiledFace] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([CompiledFace].self, from: data) else { return [] }
        return list.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    /// Copies the file into Mirante's storage. Returns the stored record, or
    /// nil when the copy fails. Newest faces are kept on top.
    static func add(copying source: URL, name: String) -> CompiledFace? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        let safeExt = (ext == "bin" || ext == "face") ? ext : "bin"
        let dest = directory
            .appendingPathComponent("\(sanitized(name))-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(safeExt)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            return nil
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        let face = CompiledFace(
            name: name,
            fileExtension: safeExt,
            sizeBytes: size,
            addedAt: Date(),
            fileURL: dest
        )
        var list = load()
        list.insert(face, at: 0)
        if list.count > maxCount {
            for old in list.suffix(from: maxCount) {
                try? FileManager.default.removeItem(at: old.fileURL)
            }
            list = Array(list.prefix(maxCount))
        }
        if let encoded = try? JSONEncoder().encode(list) {
            try? encoded.write(to: indexURL)
        }
        return face
    }

    static func remove(_ face: CompiledFace) {
        try? FileManager.default.removeItem(at: face.fileURL)
        var list = load()
        list.removeAll { $0.id == face.id }
        if let encoded = try? JSONEncoder().encode(list) {
            try? encoded.write(to: indexURL)
        }
    }

    private static func sanitized(_ name: String) -> String {
        let allowed = name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        return allowed.isEmpty ? "face" : allowed
    }
}
