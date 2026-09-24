import CoreGraphics
import Foundation
import XCTest

@testable import Mirante

final class WatchFaceProjectTests: XCTestCase {

    private func bandDevice() throws -> Device {
        try XCTUnwrap(Device.find("xiaomi_band_10_pro"))
    }

    func testNewDefaults() throws {
        let device = try bandDevice()
        let project = WatchFaceProject.new(name: "My Face", device: device)

        XCTAssertEqual(project.name, "My Face")
        XCTAssertEqual(project.deviceID, device.id)
        XCTAssertEqual(project.format, .fprj)
        XCTAssertFalse(project.usesAOD)
        XCTAssertTrue(project.widgets.isEmpty)
        XCTAssertTrue(project.aodWidgets.isEmpty)
        XCTAssertEqual(project.device, device)
        XCTAssertEqual(project.screenSize, CGSize(width: 336, height: 480))
    }

    func testNewResolvesDeviceIndependentlyOfInput() throws {
        let device = try bandDevice()
        let project = WatchFaceProject.new(name: "Untitled", device: device)
        XCTAssertEqual(project.device.id, "xiaomi_band_10_pro")
        XCTAssertEqual(project.device, device)
    }

    func testTouchAdvancesUpdatedAt() {
        var project = WatchFaceProject.new(name: "Touch", device: Device.all[0])
        project.updatedAt = Date(timeIntervalSince1970: 1_000)
        let before = project.updatedAt

        project.touch()

        XCTAssertGreaterThan(project.updatedAt, before)
    }

    func testUnknownDeviceFallsBackToFirstCatalogDevice() {
        let project = WatchFaceProject(name: "Unknown", deviceID: "not_a_real_device")
        XCTAssertEqual(project.device, Device.all[0])
    }

    func testCodableRoundTripPreservesEverything() throws {
        let device = try bandDevice()
        var project = WatchFaceProject.new(name: "Face", device: device)
        project.format = .gmf
        project.usesAOD = true
        project.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var main = WidgetItem(kind: .digitalNumber, name: "Seconds")
        main.digits = 5
        var aod = WidgetItem(kind: .image, name: "Bg")
        aod.bitmap = "aod.bmp"
        project.widgets = [main]
        project.aodWidgets = [aod]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(WatchFaceProject.self, from: data)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.deviceID, "xiaomi_band_10_pro")
        XCTAssertEqual(decoded.format, .gmf)
        XCTAssertTrue(decoded.usesAOD)
        XCTAssertEqual(decoded.widgets, [main])
        XCTAssertEqual(decoded.aodWidgets, [aod])
        XCTAssertEqual(decoded.screenSize, CGSize(width: 336, height: 480))
    }

    func testProjectFormatDefaultsAndDisplayNames() {
        XCTAssertEqual(ProjectFormat.allCases, [.fprj, .gmf])
        XCTAssertEqual(ProjectFormat.fprj.fileExtension, "fprj")
        XCTAssertEqual(ProjectFormat.gmf.fileExtension, "gmf")
        for format in ProjectFormat.allCases {
            XCTAssertFalse(format.displayName.isEmpty)
            XCTAssertFalse(format.rawValue.isEmpty)
        }
    }
}