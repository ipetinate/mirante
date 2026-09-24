import Foundation
import XCTest

@testable import Mirante

final class DataSourceTests: XCTestCase {

    func testCatalogIdsAreUnique() {
        let ids = DataSourceCatalog.common.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "data source ids must be unique")
    }

    func testNoneIsFirst() {
        let none = DataSourceCatalog.common.first
        XCTAssertEqual(none?.id, "0")
        XCTAssertEqual(none?.name, "None")
        XCTAssertEqual(DataSourceCatalog.name(for: "0", deviceID: ""), "None")
    }

    func testForDeviceReturnsCommon() {
        XCTAssertEqual(DataSourceCatalog.forDevice("xiaomi_color"), DataSourceCatalog.common)
        XCTAssertEqual(DataSourceCatalog.forDevice("unknown_device"), DataSourceCatalog.common)
        XCTAssertEqual(DataSourceCatalog.forDevice(""), DataSourceCatalog.common)
    }

    func testNameMapping() {
        XCTAssertEqual(DataSourceCatalog.name(for: "8", deviceID: ""), "Hour")
        XCTAssertEqual(DataSourceCatalog.name(for: "10", deviceID: ""), "Second")
        XCTAssertEqual(DataSourceCatalog.name(for: "27", deviceID: ""), "Stand Up value")
        XCTAssertEqual(DataSourceCatalog.name(for: "99", deviceID: ""), "Source 99", "unknown id must fall back to 'Source <id>'")
    }

    func testPreviewValuesForSpecificSources() {
        XCTAssertEqual(DataSourceCatalog.previewValue(forSourceID: "0", deviceID: ""), "0")
        XCTAssertEqual(DataSourceCatalog.previewValue(forSourceID: "8", deviceID: ""), "10", "Hour previews 10 in 24h")
        XCTAssertEqual(DataSourceCatalog.previewValue(forSourceID: "10", deviceID: ""), "56")
        XCTAssertEqual(DataSourceCatalog.previewValue(forSourceID: "42", deviceID: ""), "0", "unknown id must preview 0")
    }

    func testKnownSourcesPreviewNonZeroExceptNone() {
        let zeroPreview = DataSourceCatalog.common
            .filter { $0.id != "0" }
            .filter { DataSourceCatalog.previewValue(forSourceID: $0.id, deviceID: "") == "0" }
            .map(\.id)

        XCTAssertEqual(zeroPreview, ["19"], "Battery charging status (19) lacks a simulated preview value")
    }

    func testDataSourceCodableRoundTrip() throws {
        for source in DataSourceCatalog.common {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(DataSource.self, from: data)
            XCTAssertEqual(decoded, source)
        }
    }
}