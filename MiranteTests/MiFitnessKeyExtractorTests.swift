import Foundation
import XCTest

@testable import Mirante

final class MiFitnessKeyExtractorTests: XCTestCase {
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
}
