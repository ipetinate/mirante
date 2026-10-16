import Foundation
import XCTest
import SQLite3

@testable import Mirante

final class MiFitnessKeyExtractorTests: XCTestCase {
    func testAuthKeyCandidatesExcludeBeaconAndIRKKeysAndCollapseAliases() {
        let authKey = "0123456789abcdef0123456789abcdef"
        let keys = [
            MiFitnessKeyExtractor.FoundKey(file: "manifest.sqlite", key: "beaconkey", value: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            MiFitnessKeyExtractor.FoundKey(file: "manifest.sqlite", key: "irq_key", value: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            MiFitnessKeyExtractor.FoundKey(file: "manifest.sqlite", key: "token", value: authKey),
            MiFitnessKeyExtractor.FoundKey(file: "manifest.sqlite", key: "encrypt_key", value: authKey),
            MiFitnessKeyExtractor.FoundKey(file: "manifest.sqlite", key: "encryptKey", value: authKey),
            MiFitnessKeyExtractor.FoundKey(file: "manifest.sqlite", key: "encryptKey", value: "not-hex")
        ]

        let candidates = MiFitnessKeyExtractor.authKeyCandidates(from: keys)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].key, "encryptKey")
        XCTAssertEqual(candidates[0].value, authKey)
    }

    func testScansRegisterListFileAndFindsAuthKeyCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiranteKeyScan-\(UUID().uuidString)", isDirectory: true)
        let registration = root
            .appendingPathComponent("VirtualDevice_registerList", isDirectory: true)
        try FileManager.default.createDirectory(at: registration, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authKey = "0123456789abcdef0123456789abcdef"
        let plist: [String: Any] = [
            "list": [[
                "name": "Xiaomi Smart Band 10 Pro",
                "mac": "AA:BB:CC:DD:EE:FF",
                "auth_key": authKey
            ]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let file = registration.appendingPathComponent("registerList_us")
        try data.write(to: file)

        let found = MiFitnessKeyExtractor.extractKeys(from: root)
        XCTAssertTrue(found.contains { $0.key == "auth_key" && $0.value == authKey })
        XCTAssertTrue(found.contains { $0.isAuthKeyCandidate })
        XCTAssertEqual(found.first?.file, "registerList_us")
    }

    func testDecodesKeyedArchiveAndDoesNotRequireFilenameMatchForSelectedFile() throws {
        let authKey = "abcdef0123456789abcdef0123456789"
        let registration: [String: Any] = ["list": [["name": "Smart Band", "auth_key": authKey]]]
        let data = try NSKeyedArchiver.archivedData(withRootObject: registration, requiringSecureCoding: false)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mi-fitness-export.data")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let found = MiFitnessKeyExtractor.extractKeys(from: file)
        XCTAssertTrue(found.contains { $0.key == "auth_key" && $0.value == authKey })
    }

    func testFindsEncryptKeyUnderRegionNamedRegisterList() throws {
        let authKey = "0123456789abcdef0123456789abcdef"
        let registration: [String: Any] = [
            "registerList_sg": [["deviceName": "Xiaomi Smart Band 10 Pro", "encryptKey": authKey]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: registration, format: .binary, options: 0)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mi-fitness-region-cache")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let found = MiFitnessKeyExtractor.extractKeys(from: file)
        XCTAssertTrue(found.contains { $0.key == "encryptKey" && $0.value == authKey })
    }

    func testResolvesKeyedArchiveWhenArchivedClassIsUnavailable() throws {
        let authKey = "0123456789abcdef0123456789abcdef"
        NSKeyedArchiver.setClassName("MiJiaWear.MIWPeripheralList", for: FakePeripheralList.self)
        defer { NSKeyedArchiver.setClassName(nil, for: FakePeripheralList.self) }

        let archive = FakePeripheralList(list: [
            ["name": "Xiaomi Smart Band 10 Pro", "mac": "AA:BB:CC:DD:EE:FF", "auth_key": authKey]
        ])
        let data = try NSKeyedArchiver.archivedData(withRootObject: archive, requiringSecureCoding: false)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("registerList_us")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        XCTAssertThrowsError(try unarchiver.decodeTopLevelObject(forKey: NSKeyedArchiveRootObjectKey))

        let found = MiFitnessKeyExtractor.extractKeys(from: file)
        XCTAssertTrue(found.contains { $0.key == "auth_key" && $0.value == authKey }, "found: \(found)")
    }

    func testReadsRegionalRegisterListInlineDataFromMiFitnessManifestDatabase() throws {
        let authKey = "fedcba9876543210fedcba9876543210"
        let registration: [String: Any] = ["list": [["name": "Smart Band", "encryptKey": authKey]]]
        let archive = try NSKeyedArchiver.archivedData(withRootObject: registration, requiringSecureCoding: false)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiranteManifest-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("MHWCahe/device/VirtualDevice_registerList/manifest.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE manifest (key TEXT PRIMARY KEY, filename TEXT, size INTEGER, inline_data BLOB, modification_time INTEGER, last_access_time INTEGER, extended_data BLOB)",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        var insert: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "INSERT INTO manifest(key, inline_data) VALUES ('registerList_de', ?)", -1, &insert, nil),
            SQLITE_OK
        )
        let result = archive.withUnsafeBytes { bytes in
            sqlite3_bind_blob(insert, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(result, SQLITE_OK)
        XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
        sqlite3_finalize(insert)
        sqlite3_close(database)
        database = nil

        let found = MiFitnessKeyExtractor.extractKeys(from: root)
        XCTAssertTrue(found.contains { $0.key == "encryptKey" && $0.value == authKey }, "Expected regional registerList archive to be parsed")
    }
}

@objc(FakePeripheralList)
final class FakePeripheralList: NSObject, NSCoding {
    let list: [NSDictionary]

    init(list: [NSDictionary]) { self.list = list }

    func encode(with coder: NSCoder) { coder.encode(list, forKey: "list") }

    required init?(coder: NSCoder) {
        list = (coder.decodeObject(forKey: "list") as? [NSDictionary]) ?? []
    }
}
