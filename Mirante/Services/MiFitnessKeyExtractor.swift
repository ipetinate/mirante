import Foundation
import ZIPFoundation
import SQLite3

/// Extracts pairing keys from a Mi Fitness registration file. On iOS the app's
/// sandbox cannot read Mi Fitness's own containers, so the user supplies the
/// registration data directly: the `VirtualDevice_registerList/registerList_us`
/// property list from an iPhone backup (as produced by e.g. an iPhone backup
/// extractor), or a copy placed anywhere pickable from the Files app.
///
/// The registration list may be a standalone keyed-archive plist, or the
/// `inline_data` blob in Mi Fitness' `manifest.sqlite` (`key` is
/// `registerList_<region>`). Key names for the same secret vary across firmware versions,
/// so Mirante surfaces every discovered value and lets the user confirm which
/// hex belongs to which band.
enum MiFitnessKeyExtractor {
    struct FoundKey: Identifiable, Hashable {
        var id: String { "\(file)-\(key)-\(value)" }
        /// Name of the file the key came from (helps when a backup has several
        /// bands).
        let file: String
        /// The property key inside the device record (e.g. "irq_key").
        let key: String
        /// The stored value (a 32-hex secret, a MAC, etc).
        let value: String

        /// Only the registration's device encryption/authentication fields are
        /// suitable for the band handshake. Other 32-hex values (IRK, beacon
        /// key, token, etc.) have different purposes and must not be offered.
        var authKeyPriority: Int? {
            guard value.count == 32,
                  value.unicodeScalars.allSatisfy(CharacterSet.hexSet.contains) else { return nil }
            switch key.lowercased() {
            case "encryptkey": return 0
            case "encrypt_key": return 1
            case "authkey": return 2
            case "auth_key": return 3
            default: return nil
            }
        }

        var isAuthKeyCandidate: Bool {
            authKeyPriority != nil
        }
    }

    /// Orders documented Mi Fitness auth-key fields first and collapses aliases
    /// when they contain the same secret (e.g. `encryptKey` and `encrypt_key`).
    static func authKeyCandidates(from keys: [FoundKey]) -> [FoundKey] {
        let ordered = keys
            .filter(\.isAuthKeyCandidate)
            .sorted { lhs, rhs in
                let leftPriority = lhs.authKeyPriority ?? Int.max
                let rightPriority = rhs.authKeyPriority ?? Int.max
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                if lhs.file != rhs.file { return lhs.file.localizedStandardCompare(rhs.file) == .orderedAscending }
                return lhs.key < rhs.key
            }
        var seenValues = Set<String>()
        return ordered.filter { seenValues.insert($0.value.lowercased()).inserted }
    }

    /// Scans a file or directory for Mi Fitness registration data and returns
    /// every pairing key found, tagged by the key name and source file.
    static func extractKeys(from url: URL) -> [FoundKey] {
        // URLs returned by the Files document picker may require a temporary
        // security-scoped access grant. Keep it alive for enumeration and all
        // SQLite/plist reads; ordinary in-container URLs simply return false.
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var results: [FoundKey] = []
        for file in candidateFiles(from: url) {
            guard let data = try? Data(contentsOf: file) else { continue }
            if data.starts(with: Array("SQLite format 3\0".utf8)) {
                results += extractKeysFromSQLite(at: file, fileName: file.lastPathComponent)
                continue
            }
            results += extractKeys(from: data, fileName: file.lastPathComponent)
        }
        return results
    }

    private static func extractKeys(from data: Data, fileName: String) -> [FoundKey] {
        if data.starts(with: Array("SQLite format 3\0".utf8)) {
            return extractKeysFromSQLite(data, fileName: fileName)
        }

        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]),
           let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) {
            return archive
                .filter {
                    $0.type == .file && (
                        $0.path.lowercased().contains("registerlist")
                            || $0.path.lowercased().hasSuffix("manifest.sqlite")
                    )
                }
                .flatMap { entry -> [FoundKey] in
                    var payload = Data()
                    guard (try? archive.extract(entry) { payload.append($0) }) != nil else { return [] }
                    return extractKeys(from: payload, fileName: entry.path)
                }
        }

        // Mi Fitness backups store a real NSKeyedArchiver graph. Decoding it as
        // an object fails when the archiving app's classes are unavailable (e.g.
        // MiJiaWear.MIWPeripheralList), and reading the raw plist leaves values
        // hidden behind $objects/UIDs. So try the object decoder, then fall back
        // to resolving the archive graph by hand.
        var roots: [Any] = []
        if let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = false
            do {
                if let object = try unarchiver.decodeTopLevelObject(forKey: NSKeyedArchiveRootObjectKey) {
                    roots.append(object)
                }
            } catch {
                // Continue with raw plist resolution when the archived class is unavailable.
            }
            unarchiver.finishDecoding()
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            roots.append(resolveKeyedArchive(plist) ?? plist)
        }

        var found: [FoundKey] = []
        for root in roots {
            // The registration array is named by Xiaomi region in some app
            // versions (for example `registerList_de`), rather than always
            // appearing under a literal `list` key. Walk the complete plist
            // graph so those regional wrappers do not hide `encryptKey`.
            for (key, value) in stringPairs(in: root) {
                let lowerKey = key.lowercased()
                let is32Hex = value.count == 32 && value.unicodeScalars.allSatisfy(CharacterSet.hexSet.contains)
                if lowerKey.contains("key") || lowerKey == "mac" || lowerKey == "random_mac" || is32Hex {
                    found.append(FoundKey(file: fileName, key: key, value: value))
                }
            }
        }
        return Array(Set(found))
    }

    /// Mi Fitness iPhone backups can place the keyed-archive register list in
    /// a SQLite `manifest.sqlite` rather than exporting `registerList_us` as a
    /// standalone file. Inspect table values (including BLOBs) and feed each
    /// candidate back through the plist/ZIP decoder above.
    private static func extractKeysFromSQLite(_ data: Data, fileName: String) -> [FoundKey] {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mirante-MiFitness-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard (try? data.write(to: temporaryURL, options: .atomic)) != nil else { return [] }
        return extractKeysFromSQLite(at: temporaryURL, fileName: fileName)
    }

    private static func extractKeysFromSQLite(at url: URL, fileName: String) -> [FoundKey] {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            url.path, &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }

        var tables: [String] = []
        var tableStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type='table'", -1, &tableStatement, nil) == SQLITE_OK {
            while sqlite3_step(tableStatement) == SQLITE_ROW {
                if let name = sqlite3_column_text(tableStatement, 0) {
                    tables.append(String(cString: name))
                }
            }
        }
        sqlite3_finalize(tableStatement)

        // This is the schema used by Mi Fitness backups: one row per logical
        // file, with the actual registerList archive in `inline_data`. Read
        // that column explicitly first; scanning arbitrary columns misses the
        // real layout when the selected item is the app's manifest directory.
        var candidates: [Data] = []
        var registrationStatement: OpaquePointer?
        if sqlite3_prepare_v2(
            database,
            "SELECT inline_data FROM manifest WHERE key GLOB 'registerList_*' AND inline_data IS NOT NULL",
            -1,
            &registrationStatement,
            nil
        ) == SQLITE_OK {
            while sqlite3_step(registrationStatement) == SQLITE_ROW {
                let type = sqlite3_column_type(registrationStatement, 0)
                guard type == SQLITE_BLOB || type == SQLITE_TEXT else { continue }
                let count = Int(sqlite3_column_bytes(registrationStatement, 0))
                guard count > 0, let bytes = sqlite3_column_blob(registrationStatement, 0) else { continue }
                candidates.append(Data(bytes: bytes, count: count))
            }
        }
        sqlite3_finalize(registrationStatement)

        if !candidates.isEmpty {
            return candidates.flatMap { extractKeys(from: $0, fileName: fileName) }
        }

        // Retain the generic fallback for older/newer Mi Fitness schemas and
        // standalone SQLite exports that do not use the documented table.
        for table in tables {
            let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
            var columnsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(quotedTable))", -1, &columnsStatement, nil) == SQLITE_OK else {
                sqlite3_finalize(columnsStatement)
                continue
            }
            var columns: [String] = []
            while sqlite3_step(columnsStatement) == SQLITE_ROW {
                if let name = sqlite3_column_text(columnsStatement, 1) {
                    columns.append(String(cString: name))
                }
            }
            sqlite3_finalize(columnsStatement)

            for column in columns {
                let quotedColumn = "\"\(column.replacingOccurrences(of: "\"", with: "\"\""))\""
                var valuesStatement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "SELECT \(quotedColumn) FROM \(quotedTable)", -1, &valuesStatement, nil) == SQLITE_OK else {
                    sqlite3_finalize(valuesStatement)
                    continue
                }
                while sqlite3_step(valuesStatement) == SQLITE_ROW {
                    let type = sqlite3_column_type(valuesStatement, 0)
                    guard type == SQLITE_BLOB || type == SQLITE_TEXT else { continue }
                    let count = Int(sqlite3_column_bytes(valuesStatement, 0))
                    guard count > 0, let bytes = sqlite3_column_blob(valuesStatement, 0) else { continue }
                    candidates.append(Data(bytes: bytes, count: count))
                }
                sqlite3_finalize(valuesStatement)
            }
        }

        return candidates.flatMap { extractKeys(from: $0, fileName: fileName) }
    }

    /// Flattens a device record into name/value string pairs, descending through
    /// nested dictionaries (some firmware stores the secret under `detail`).
    private static func stringPairs(in object: Any) -> [(String, String)] {
        var out: [(String, String)] = []
        func walk(_ value: Any) {
            if let dictionary = value as? NSDictionary {
                for (keyObject, valueObject) in dictionary {
                    guard let key = keyObject as? String else { continue }
                    if let string = valueObject as? String, !string.isEmpty {
                        out.append((key, string))
                    } else {
                        walk(valueObject)
                    }
                }
            } else if let array = value as? NSArray {
                for element in array { walk(element) }
            }
        }
        walk(object)
        return out
    }

    /// Resolves an `NSKeyedArchiver` plist graph (the `$objects`/`$top` shape)
    /// into plain dictionaries, arrays and values, following the UID references
    /// that the raw plist leaves unresolved. Returns `nil` for plists that are
    /// not keyed archives so callers can use them as-is.
    private static func resolveKeyedArchive(_ plist: Any) -> Any? {
        guard let root = plist as? [String: Any],
              let objects = root["$objects"] as? [Any],
              let top = root["$top"] as? [String: Any] else { return nil }
        let resolver = KeyedArchiveResolver(objects: objects)
        let rootObject = top["root"] ?? top
        return resolver.resolve(rootObject)
    }

    /// Reads the index out of an NSKeyedArchiver UID node. UIDs surface as an
    /// opaque `CFKeyedArchiverUID` whose only public representation is its
    /// description (`<CFKeyedArchiverUID 0x…>{value = N}`), so the index is
    /// parsed from there. Container descriptions embed their children's
    /// descriptions, hence the prefix check to accept only leaf UIDs.
    private static func uidIndex(_ object: Any) -> Int? {
        let description = String(describing: object)
        guard description.hasPrefix("<CFKeyedArchiverUID"),
              let range = description.range(of: "value = ") else { return nil }
        return Int(description[range.upperBound...].prefix { $0.isNumber })
    }

    private struct KeyedArchiveResolver {
        let objects: [Any]

        func resolve(_ object: Any, depth: Int = 0) -> Any {
            guard depth < 64 else { return NSNull() }
            if let index = uidIndex(object), objects.indices.contains(index) {
                return resolve(objects[index], depth: depth + 1)
            }
            if let dictionary = object as? [String: Any] {
                let values = dictionary["NS.objects"] as? [Any]
                let keys = dictionary["NS.keys"] as? [Any]
                if let keys, let values {
                    var out: [String: Any] = [:]
                    for (key, value) in zip(keys, values) {
                        if let name = resolve(key, depth: depth + 1) as? String {
                            out[name] = resolve(value, depth: depth + 1)
                        }
                    }
                    return out
                }
                if let values {
                    return values.map { resolve($0, depth: depth + 1) }
                }
                var out: [String: Any] = [:]
                for (key, value) in dictionary where !key.hasPrefix("$") {
                    out[key] = resolve(value, depth: depth + 1)
                }
                return out
            }
            if let array = object as? [Any] {
                return array.map { resolve($0, depth: depth + 1) }
            }
            if let string = object as? String, string == "$null" { return NSNull() }
            return object
        }

        private func uidIndex(_ object: Any) -> Int? {
            MiFitnessKeyExtractor.uidIndex(object)
        }
    }

    private static func candidateFiles(from url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }

        if !isDir.boolValue { return [url] }

        var out: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true else { continue }
            let name = file.lastPathComponent.lowercased()
            if name.contains("registerlist") || name == "manifest.sqlite" {
                out.append(file)
            }
        }
        return out
    }

}
