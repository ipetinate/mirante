import Foundation

/// Extracts pairing keys from a Mi Fitness registration file. On iOS the app's
/// sandbox cannot read Mi Fitness's own containers, so the user supplies the
/// registration data directly: the `VirtualDevice_registerList/registerList_us`
/// property list from an iPhone backup (as produced by e.g. an iPhone backup
/// extractor), or a copy placed anywhere pickable from the Files app.
///
/// The file is a plist (XML or binary) whose root object follows the
/// NSKeyedArchiver shape: a dictionary with a `list` of per-device
/// dictionaries. Key names for the same secret vary across firmware versions,
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

        var isAuthKeyCandidate: Bool {
            value.count == 32 && value.unicodeScalars.allSatisfy(CharacterSet.hexSet.contains)
        }
    }

    /// Scans a file or directory for Mi Fitness registration data and returns
    /// every pairing key found, tagged by the key name and source file.
    static func extractKeys(from url: URL) -> [FoundKey] {
        var results: [FoundKey] = []
        for file in candidateFiles(from: url) {
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let root = plist as? NSDictionary else { continue }

            var dictionaries: [NSDictionary] = []
            collectDictionaries(root, into: &dictionaries)

            let fileName = file.lastPathComponent
            for record in dictionaries {
                guard let recordList = record["list"] as? NSArray else { continue }
                for case let device as NSDictionary in recordList {
                    for (keyObj, valueObj) in device {
                        guard let key = keyObj as? String,
                              let value = valueObj as? String,
                              !value.isEmpty else { continue }

                        let lowerKey = key.lowercased()
                        let is32Hex = value.count == 32
                            && value.unicodeScalars.allSatisfy(CharacterSet.hexSet.contains)
                        let useful = lowerKey.contains("key")
                            || lowerKey == "mac"
                            || lowerKey == "random_mac"
                            || is32Hex
                        if useful {
                            results.append(FoundKey(file: fileName, key: key, value: value))
                        }
                    }
                }
            }
        }
        return results
    }

    private static func candidateFiles(from url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }

        if !isDir.boolValue {
            return url.lastPathComponent.lowercased().contains("registerlist") ? [url] : []
        }

        var out: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true else { continue }
            if file.lastPathComponent.lowercased().contains("registerlist") {
                out.append(file)
            }
        }
        return out
    }

    private static func collectDictionaries(_ object: Any, into out: inout [NSDictionary]) {
        if let dictionary = object as? NSDictionary {
            out.append(dictionary)
            for value in dictionary.allValues {
                collectDictionaries(value, into: &out)
            }
        } else if let array = object as? NSArray {
            for value in array {
                collectDictionaries(value, into: &out)
            }
        }
    }
}