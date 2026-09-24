import Foundation
import XCTest

@testable import Mirante

final class FprjExporterTests: XCTestCase {

    private func bandDevice() throws -> Device {
        try XCTUnwrap(Device.find("xiaomi_band_10_pro"))
    }

    private func widgetLine(containing needle: String, in xml: String) -> String {
        xml.components(separatedBy: .newlines).first { $0.contains(needle) } ?? ""
    }

    func testExportStartsWithFaceProjectRootAndScreenDimensions() throws {
        var project = WatchFaceProject.new(name: "Face", device: try bandDevice())
        let xml = FprjExporter.export(project)

        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<FaceProject"))
        XCTAssertTrue(xml.contains("Name=\"Face\""))
        XCTAssertTrue(xml.contains("DeviceType=\"xiaomi_band_10_pro\""))
        XCTAssertTrue(xml.contains("Width=\"336\""))
        XCTAssertTrue(xml.contains("Height=\"480\""))
        XCTAssertTrue(xml.hasSuffix("</FaceProject>\n"))
        XCTAssertTrue(xml.contains("<Screen Name=\"main\">"))
        XCTAssertFalse(xml.contains("<Screen Name=\"aod\">"), "aod screen must be absent when usesAOD is false")
    }

    func testExportEscapesAttributeValues() throws {
        var project = WatchFaceProject.new(name: "A&B \"Round\" <Face>", device: try bandDevice())
        let xml = FprjExporter.export(project)

        XCTAssertTrue(xml.contains("Name=\"A&amp;B &quot;Round&quot; &lt;Face&gt;\""))
        XCTAssertFalse(xml.contains("Name=\"A&B"), "raw unescaped characters must not appear")
    }

    func testExportShapeCodesPerWidgetKind() throws {
        var project = WatchFaceProject.new(name: "Shapes", device: try bandDevice())
        project.widgets = WidgetKind.allCases.map { WidgetItem(kind: $0, name: $0.rawValue) }

        let xml = FprjExporter.export(project)

        XCTAssertEqual(xml.components(separatedBy: "<Widget ").count - 1, WidgetKind.allCases.count)
        XCTAssertTrue(xml.contains("@Shape=\"30\""))
        XCTAssertTrue(xml.contains("@Shape=\"31\""))
        XCTAssertTrue(xml.contains("@Shape=\"32\""))
        XCTAssertEqual(xml.components(separatedBy: "@Shape=\"27\"").count - 1, 2, "analog and pointer both map to 27")
        XCTAssertTrue(xml.contains("@Shape=\"42\""))
        XCTAssertTrue(xml.contains("@Shape=\"34\""))
    }

    func testExportRadiusOnlyWhenGreaterThanZero() throws {
        let device = try bandDevice()
        var project = WatchFaceProject.new(name: "Radius", device: device)

        var plain = WidgetItem(kind: .image, name: "NoRadius")
        plain.radius = 0
        var rounded = WidgetItem(kind: .image, name: "HasRadius")
        rounded.radius = 12
        project.widgets = [plain, rounded]

        let xml = FprjExporter.export(project)
        let plainLine = widgetLine(containing: "@Name=\"NoRadius\"", in: xml)
        let roundedLine = widgetLine(containing: "@Name=\"HasRadius\"", in: xml)

        XCTAssertFalse(plainLine.contains("@Radius"), "radius 0 must omit @Radius")
        XCTAssertTrue(roundedLine.contains("@Radius=\"12\""), "radius > 0 must emit @Radius")
    }

    func testExportImageWidget() throws {
        var widget = WidgetItem(kind: .image, name: "Photo")
        widget.bitmap = "photo.bmp"
        widget.alpha = 200
        widget.visible = true
        widget.visibleSourceID = "20"
        widget.x = 2
        widget.y = 3
        widget.width = 120
        widget.height = 90

        var project = WatchFaceProject.new(name: "Image", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"Photo\"", in: xml)

        XCTAssertTrue(line.contains("@Bitmap=\"photo.bmp\""))
        XCTAssertTrue(line.contains("@Alpha=\"200\""))
        XCTAssertTrue(line.contains("@Visible_Src=\"20\""))
        XCTAssertTrue(line.contains("@X=\"2\""))
        XCTAssertTrue(line.contains("@Y=\"3\""))
        XCTAssertTrue(line.contains("@Width=\"120\""))
        XCTAssertTrue(line.contains("@Height=\"90\""))
        XCTAssertTrue(line.contains("@Id="))
    }

    func testExportHiddenWidgetUsesVisibleSrcZero() throws {
        var widget = WidgetItem(kind: .image, name: "Hidden")
        widget.visible = false
        widget.visibleSourceID = "20"

        var project = WatchFaceProject.new(name: "Hidden", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)

        XCTAssertTrue(xml.contains("@Visible_Src=\"-1\""))
        XCTAssertFalse(xml.contains("@Visible_Src=\"20\""))
    }

    func testExportImageListWidget() throws {
        var widget = WidgetItem(kind: .imageList, name: "Slides")
        widget.bitmapList = ["a.bmp", "b.bmp"]
        widget.indexSourceID = "10"
        widget.defaultIndex = 1

        var project = WatchFaceProject.new(name: "List", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"Slides\"", in: xml)

        XCTAssertTrue(line.contains("@BitmapList=\"a.bmp,b.bmp\""))
        XCTAssertTrue(line.contains("@Index_Src=\"10\""))
        XCTAssertTrue(line.contains("@DefaultIndex=\"1\""))
    }

    func testExportDigitalNumberWidget() throws {
        var widget = WidgetItem(kind: .digitalNumber, name: "Digits")
        widget.valueSourceID = "8"
        widget.digits = 4
        widget.spacing = 6
        widget.alignment = 2

        var project = WatchFaceProject.new(name: "Num", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"Digits\"", in: xml)

        XCTAssertTrue(line.contains("@Value_Src=\"8\""))
        XCTAssertTrue(line.contains("@Digits=\"4\""))
        XCTAssertTrue(line.contains("@Spacing=\"6\""))
        XCTAssertTrue(line.contains("@Alignment=\"2\""))
    }

    func testExportAnalogWidget() throws {
        var widget = WidgetItem(kind: .analog, name: "Analog")
        widget.hourHandImage = "h.bmp"
        widget.minuteHandImage = "m.bmp"
        widget.secondHandImage = "s.bmp"
        widget.background = "bg.bmp"
        widget.foreground = "fg.bmp"
        widget.rotateCenterX = 60
        widget.rotateCenterY = 50

        var project = WatchFaceProject.new(name: "Analog", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"Analog\"", in: xml)

        XCTAssertTrue(line.contains("@HourHand_ImageName=\"h.bmp\""))
        XCTAssertTrue(line.contains("@MinuteHand_ImageName=\"m.bmp\""))
        XCTAssertTrue(line.contains("@SecondHand_ImageName=\"s.bmp\""))
        XCTAssertTrue(line.contains("@Background_ImageName=\"bg.bmp\""))
        XCTAssertTrue(line.contains("@Foreground_ImageName=\"fg.bmp\""))
        XCTAssertTrue(line.contains("@Rotate_xc=\"60\""))
        XCTAssertTrue(line.contains("@Rotate_yc=\"50\""))
    }

    func testExportAnalogOmitsEmptyHandImages() throws {
        var widget = WidgetItem(kind: .analog, name: "BareAnalog")
        widget.hourHandImage = "h.bmp"

        var project = WatchFaceProject.new(name: "Bare", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"BareAnalog\"", in: xml)

        XCTAssertFalse(line.contains("@MinuteHand_ImageName"))
        XCTAssertFalse(line.contains("@SecondHand_ImageName"))
        XCTAssertFalse(line.contains("@Background_ImageName"))
        XCTAssertFalse(line.contains("@Foreground_ImageName"))
    }

    func testExportArcWidget() throws {
        var widget = WidgetItem(kind: .arc, name: "Progress")
        widget.valueSourceID = "23"
        widget.arcStartAngle = -90
        widget.arcEndAngle = 270
        widget.arcLineWidth = 9
        widget.rangeMin = 0
        widget.rangeMax = 1000

        var project = WatchFaceProject.new(name: "Arc", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"Progress\"", in: xml)

        XCTAssertTrue(line.contains("@Value_Src=\"23\""))
        XCTAssertTrue(line.contains("@StartAngle=\"-90.0\""))
        XCTAssertTrue(line.contains("@EndAngle=\"270.0\""))
        XCTAssertTrue(line.contains("@Line_Width=\"9\""))
        XCTAssertTrue(line.contains("@Range_Min=\"0\""))
        XCTAssertTrue(line.contains("@Range_Max=\"1000\""))
    }

    func testExportContainerWidget() throws {
        let device = try bandDevice()
        var project = WatchFaceProject.new(name: "Container", device: device)
        project.widgets = [WidgetItem(kind: .container, name: "Box")]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"Box\"", in: xml)

        XCTAssertTrue(line.contains("@DeviceType=\"xiaomi_band_10_pro\""))
    }

    func testExportPointerWidget() throws {
        var widget = WidgetItem(kind: .pointer, name: "Needle")
        widget.pointerImage = "ptr.bmp"
        widget.valueSourceID = "8"
        widget.width = 200
        widget.height = 120
        widget.pointerAnchorX = 0.5
        widget.pointerAnchorY = 0.25

        var project = WatchFaceProject.new(name: "Pointer", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"Needle\"", in: xml)

        XCTAssertTrue(line.contains("@Bitmap=\"ptr.bmp\""))
        XCTAssertTrue(line.contains("@Value_Src=\"8\""))
        XCTAssertTrue(line.contains("@Rotate_xc=\"100\""))
        XCTAssertTrue(line.contains("@Rotate_yc=\"30\""))
    }

    func testExportPolylineWidget() throws {
        var widget = WidgetItem(kind: .polyline, name: "Steps")
        widget.width = 200
        widget.height = 40
        widget.lineWidth = 7
        widget.pointList = [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)]
        widget.colorR = 10
        widget.colorG = 20
        widget.colorB = 30

        var project = WatchFaceProject.new(name: "Poly", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"Steps\"", in: xml)

        XCTAssertTrue(line.contains("@Shape=\"33\""))
        XCTAssertTrue(line.contains("@Line_Width=\"7\""))
        XCTAssertTrue(line.contains("@Points=\"0,50 50,50 100,100\""))
        XCTAssertTrue(line.contains("@Color=\"0A141E\""))
    }

    func testExportColorAttributeOnlyForColorKinds() throws {
        var widget = WidgetItem(kind: .image, name: "Photo")
        widget.colorR = 1
        widget.colorG = 2
        widget.colorB = 3

        var project = WatchFaceProject.new(name: "Colors", device: try bandDevice())
        project.widgets = [widget]
        let xml = FprjExporter.export(project)
        let line = widgetLine(containing: "@Name=\"Photo\"", in: xml)

        XCTAssertFalse(line.contains("@Color"), "image widgets must not export @Color")
    }

    func testExportIncludesAODScreenWhenEnabled() throws {
        let device = try bandDevice()
        var project = WatchFaceProject.new(name: "AOD", device: device)
        project.usesAOD = true
        project.widgets = [WidgetItem(kind: .image, name: "Main")]
        project.aodWidgets = [WidgetItem(kind: .digitalNumber, name: "AodTime")]

        let xml = FprjExporter.export(project)

        XCTAssertEqual(xml.components(separatedBy: "<Screen Name=\"main\">").count - 1, 1)
        XCTAssertEqual(xml.components(separatedBy: "<Screen Name=\"aod\">").count - 1, 1)
        XCTAssertEqual(xml.components(separatedBy: "<Widget ").count - 1, 2, "main + aod widgets both exported")
    }

    func testExportDataAndSuggestedFileName() throws {
        let device = try bandDevice()
        var project = WatchFaceProject.new(name: "My/Face", device: device)
        project.widgets = [WidgetItem(kind: .arc, name: "A")]

        let xml = FprjExporter.export(project)
        let data = project.exportData()

        XCTAssertEqual(data, Data(xml.utf8))
        XCTAssertEqual(project.suggestedFileName, "My-Face.fprj")
    }

    // MARK: - Round trip (export → parse)

    private func roundTripWidgets(_ widgets: [WidgetItem],
                                  device: Device = Device.all[0],
                                  file: StaticString = #filePath,
                                  line: UInt = #line) -> [WidgetItem] {
        var project = WatchFaceProject.new(name: "RoundTrip", device: device)
        project.widgets = widgets
        let parsed = FprjParser.parse(FprjExporter.export(project))
        XCTAssertNotNil(parsed, "exported xml should parse", file: file, line: line)
        return parsed?.widgets ?? []
    }

    func testRoundTripImageWidget() throws {
        var widget = WidgetItem(kind: .image, name: "Photo")
        widget.x = 12
        widget.y = 34
        widget.width = 150
        widget.height = 80
        widget.alpha = 210
        widget.visible = true
        widget.visibleSourceID = "7"
        widget.bitmap = "photo.bmp"
        widget.radius = 9

        let parsed = try XCTUnwrap(roundTripWidgets([widget]).first)
        XCTAssertEqual(parsed, widget)
    }

    func testRoundTripDigitalNumberWidget() throws {
        var widget = WidgetItem(kind: .digitalNumber, name: "Digits")
        widget.valueSourceID = "8"
        widget.digits = 4
        widget.spacing = 5
        widget.alignment = 2

        let parsed = try XCTUnwrap(roundTripWidgets([widget]).first)
        XCTAssertEqual(parsed, widget)
    }

    func testRoundTripArcWidget() throws {
        var widget = WidgetItem(kind: .arc, name: "Progress")
        widget.valueSourceID = "23"
        widget.arcStartAngle = -45
        widget.arcEndAngle = 315
        widget.arcLineWidth = 9
        widget.rangeMin = 0
        widget.rangeMax = 1000

        let parsed = try XCTUnwrap(roundTripWidgets([widget]).first)
        XCTAssertEqual(parsed, widget)
    }

    func testRoundTripPolylineWidget() throws {
        var widget = WidgetItem(kind: .polyline, name: "Steps")
        widget.width = 200
        widget.height = 40
        widget.lineWidth = 7
        widget.colorR = 10
        widget.colorG = 20
        widget.colorB = 30
        widget.pointList = [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)]

        let parsed = try XCTUnwrap(roundTripWidgets([widget]).first)
        XCTAssertEqual(parsed, widget)
    }

    func testRoundTripPointerWidget() throws {
        var widget = WidgetItem(kind: .pointer, name: "Needle")
        widget.pointerImage = "ptr.bmp"
        widget.valueSourceID = "8"
        widget.width = 200
        widget.height = 120
        widget.pointerAnchorX = 0.5
        widget.pointerAnchorY = 0.25

        let parsed = try XCTUnwrap(roundTripWidgets([widget]).first)
        XCTAssertEqual(parsed, widget)
    }

    func testRoundTripAnalogWidget() throws {
        var widget = WidgetItem(kind: .analog, name: "Analog")
        widget.hourHandImage = "h.bmp"
        widget.minuteHandImage = "m.bmp"
        widget.secondHandImage = "s.bmp"
        widget.background = "bg.bmp"
        widget.foreground = "fg.bmp"
        widget.rotateCenterX = 30
        widget.rotateCenterY = 40

        let parsed = try XCTUnwrap(roundTripWidgets([widget]).first)
        XCTAssertEqual(parsed, widget)
    }

    func testRoundTripAODScreen() throws {
        let device = try bandDevice()
        var project = WatchFaceProject.new(name: "AOD", device: device)
        project.usesAOD = true
        project.widgets = [WidgetItem(kind: .image, name: "Main")]
        project.aodWidgets = [WidgetItem(kind: .digitalNumber, name: "AodTime")]

        let parsed = try XCTUnwrap(FprjParser.parse(FprjExporter.export(project)))
        XCTAssertEqual(parsed.name, "AOD")
        XCTAssertEqual(parsed.deviceID, device.id)
        XCTAssertEqual(parsed.usesAOD, true)
        XCTAssertEqual(parsed.widgets.count, 1)
        XCTAssertEqual(parsed.aodWidgets.count, 1)
    }

    func testRoundTripShape27WithoutHandsBecomesPointer() throws {
        var project = WatchFaceProject.new(name: "Pointer", device: try bandDevice())
        project.widgets = [WidgetItem(kind: .pointer, name: "Needle")]
        let xml = FprjExporter.export(project)

        let parsed = try XCTUnwrap(FprjParser.parse(xml))
        XCTAssertEqual(parsed.widgets.first?.kind, .pointer)
    }
}

final class RecentsStoreTests: XCTestCase {
    private let unique = "RecentsTest-\(UUID().uuidString.prefix(6))"

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: RecentsStore.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        let before = preTestIndex
        // Remove only the files this test created and restore the manifest.
        for recent in RecentsStore.load() where recent.name.hasPrefix(unique) {
            try? FileManager.default.removeItem(at: recent.fileURL)
        }
        if let encoded = try? JSONEncoder().encode(before) {
            try? encoded.write(to: RecentsStore.indexURL)
        }
    }

    private var preTestIndex: [RecentProject] {
        (try? JSONDecoder().decode([RecentProject].self, from: Data(contentsOf: RecentsStore.indexURL))) ?? []
    }

    func testSaveLoadAndDedupe() throws {
        let device = Device.all[0]
        var first = WatchFaceProject.new(name: "\(unique)-A", device: device)
        first.widgets = [WidgetItem(kind: .arc, name: "Progress")]

        let r1 = RecentsStore.save(project: first)
        let r1again = RecentsStore.save(project: first)
        XCTAssertEqual(r1.fileURL, r1again.fileURL, "re-saving the same project must reuse its file")

        var second = WatchFaceProject.new(name: "\(unique)-B", device: device)
        second.widgets = [WidgetItem(kind: .digitalNumber, name: "Time")]
        let r2 = RecentsStore.save(project: second)

        let loaded = RecentsStore.load()
        XCTAssertEqual(loaded.first?.name, "\(unique)-B", "most recently saved project comes first")
        XCTAssertEqual(loaded.first?.id, r2.id)
        XCTAssertEqual(loaded.filter { $0.name.hasPrefix(unique) }.count, 2)

        let stored = try XCTUnwrap(RecentsStore.content(of: r2))
        XCTAssertEqual(stored.name, "\(unique)-B")
        XCTAssertEqual(stored.deviceID, device.id)
        XCTAssertEqual(stored.widgets.first?.kind, .digitalNumber)
    }
}