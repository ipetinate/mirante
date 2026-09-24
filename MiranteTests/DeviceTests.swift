import CoreGraphics
import Foundation
import XCTest

@testable import Mirante

final class DeviceTests: XCTestCase {

    func testCatalogIdsAreUnique() {
        let ids = Device.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "device ids must be unique")
    }

    func testCatalogDimensionsAreValid() {
        for device in Device.all {
            XCTAssertGreaterThan(device.width, 0, "\(device.id) width must be positive")
            XCTAssertGreaterThan(device.height, 0, "\(device.id) height must be positive")
            XCTAssertGreaterThanOrEqual(device.radius, 0, "\(device.id) radius must be non-negative")
        }
    }

    func testIsRoundLogic() {
        let color = try! XCTUnwrap(Device.find("xiaomi_color"))
        XCTAssertTrue(color.isRound, "454×454 with radius 227 must be round")

        let band10Pro = try! XCTUnwrap(Device.find("xiaomi_band_10_pro"))
        XCTAssertFalse(band10Pro.isRound, "336×480 with radius 48 must not be round")

        let s1Pro = try! XCTUnwrap(Device.find("xiaomi_watch_s1_pro"))
        XCTAssertTrue(s1Pro.isRound, "480×480 with radius 240 must be round")

        let band9 = try! XCTUnwrap(Device.find("xiaomi_band_9"))
        XCTAssertTrue(band9.isRound, "192×490 with radius 100 must be round")

        let band10 = try! XCTUnwrap(Device.find("xiaomi_band_10"))
        XCTAssertTrue(band10.isRound, "212×520 with radius 106 must be round")

        let band8Pro = try! XCTUnwrap(Device.find("xiaomi_band_8_pro"))
        XCTAssertFalse(band8Pro.isRound, "336×480 with radius 48 must not be round")

        let saphir = try! XCTUnwrap(Device.find("70mai_saphir"))
        XCTAssertFalse(saphir.isRound, "368×448 with radius 60 must not be round")
    }

    func testScreenSizeMatchesDimensions() {
        for device in Device.all {
            XCTAssertEqual(device.screenSize, CGSize(width: device.width, height: device.height))
        }
    }

    func testPreviewSizeAspectCoherence() {
        for device in Device.all {
            let screen = device.screenSize
            let preview = device.previewSize
            let screenAspect = screen.width / screen.height
            let previewAspect = preview.width / preview.height
            XCTAssertEqual(
                previewAspect, screenAspect, accuracy: 0.02,
                "\(device.id) preview aspect \(previewAspect) must match screen aspect \(screenAspect)"
            )
        }
    }

    func testPreviewSizesForKnownDevices() {
        let color = try! XCTUnwrap(Device.find("xiaomi_color"))
        XCTAssertEqual(color.previewSize, CGSize(width: 246, height: 246))

        let s4 = try! XCTUnwrap(Device.find("xiaomi_watch_s4"))
        XCTAssertEqual(s4.previewSize, CGSize(width: 326, height: 326))

        let band10Pro = try! XCTUnwrap(Device.find("xiaomi_band_10_pro"))
        XCTAssertEqual(band10Pro.previewSize, CGSize(width: 336, height: 480), "missing preview entry falls back to screen size")

        let saphir = try! XCTUnwrap(Device.find("70mai_saphir"))
        XCTAssertEqual(saphir.previewSize, CGSize(width: 368, height: 448), "missing preview entry falls back to screen size")
    }

    func testFindRoundTrips() throws {
        for device in Device.all {
            let found = try XCTUnwrap(Device.find(device.id))
            XCTAssertEqual(found, device)
            XCTAssertEqual(found.id, device.id)
        }
        XCTAssertNil(Device.find("no_such_device"))
        XCTAssertNil(Device.find(""))
    }
}