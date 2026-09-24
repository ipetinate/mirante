import CoreGraphics
import Foundation
import XCTest

@testable import Mirante

final class WidgetTests: XCTestCase {

    // MARK: - Polyline on-canvas editing

    @MainActor
    func testPolylineDefaultsToStraightLine() {
        let editor = EditorState()
        editor.addWidget(kind: .polyline)
        let points = editor.selectedWidget?.pointList ?? []
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0], CGPoint(x: 0.0, y: 0.5))
        XCTAssertEqual(points[1], CGPoint(x: 1.0, y: 0.5))
    }

    @MainActor
    func testPolylineTapInsertsPointOnNearestSegment() {
        let editor = EditorState()
        editor.addWidget(kind: .polyline)
        let id = editor.selectedWidget?.id ?? UUID()

        editor.insertPolylinePoint(id, at: CGPoint(x: 0.5, y: 0.4))
        let points = editor.activeWidgets[0].pointList
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[1].x, 0.5, accuracy: 0.001)
        XCTAssertEqual(points[1].y, 0.5, accuracy: 0.001)

        // Dragging the middle point down bends the line: the "tail" angles from it.
        editor.updatePolylinePoint(id, index: 1, to: CGPoint(x: 0.5, y: 0.9))
        let moved = editor.activeWidgets[0].pointList[1]
        XCTAssertEqual(moved.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(moved.y, 0.9, accuracy: 0.001)
    }

    @MainActor
    func testPolylinePointClampsToWidgetBounds() {
        let editor = EditorState()
        editor.addWidget(kind: .polyline)
        let id = editor.selectedWidget?.id ?? UUID()

        editor.updatePolylinePoint(id, index: 1, to: CGPoint(x: 2.5, y: -1))
        let point = editor.activeWidgets[0].pointList[1]
        XCTAssertEqual(point.x, 1)
        XCTAssertEqual(point.y, 0)
    }

    func testWidgetKindDisplayNamesAreNonEmpty() {
        XCTAssertEqual(WidgetKind.allCases, [.image, .imageList, .digitalNumber, .analog, .arc, .container, .pointer, .polyline])
        for kind in WidgetKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "displayName for \(kind.rawValue) must not be empty")
        }
    }

    func testWidgetKindSystemImagesAreNonEmpty() {
        for kind in WidgetKind.allCases {
            XCTAssertFalse(kind.systemImage.isEmpty, "systemImage for \(kind.rawValue) must not be empty")
        }
    }

    func testWidgetKindFprjShapeCodes() {
        XCTAssertEqual(WidgetKind.image.fprjShape, 30)
        XCTAssertEqual(WidgetKind.imageList.fprjShape, 31)
        XCTAssertEqual(WidgetKind.digitalNumber.fprjShape, 32)
        XCTAssertEqual(WidgetKind.analog.fprjShape, 27)
        XCTAssertEqual(WidgetKind.arc.fprjShape, 42)
        XCTAssertEqual(WidgetKind.container.fprjShape, 34)
        XCTAssertEqual(WidgetKind.pointer.fprjShape, 27)
        XCTAssertEqual(WidgetKind.polyline.fprjShape, 33)
    }

    func testWidgetKindCodableRoundTrip() throws {
        for kind in WidgetKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(WidgetKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func testWidgetItemCodableRoundTripPreservesAllFields() throws {
        var widget = WidgetItem(kind: .analog, name: "Analog&<\"Round\">")
        widget.id = UUID(uuidString: "3B4A6E2F-C9D1-4A2B-8F3C-7D6E5A4B3C2D")!
        widget.x = -5
        widget.y = 7
        widget.width = 240
        widget.height = 245
        widget.alpha = 123
        widget.visible = false
        widget.visibleSourceID = "20"
        widget.bitmap = "bg.bmp"
        widget.bitmapList = ["a.bmp", "b.bmp", "c.bmp"]
        widget.indexSourceID = "10"
        widget.defaultIndex = 3
        widget.radius = 40
        widget.valueSourceID = "8"
        widget.digits = 4
        widget.spacing = 6
        widget.alignment = 2
        widget.hourHandImage = "h.bmp"
        widget.minuteHandImage = "m.bmp"
        widget.secondHandImage = "s.bmp"
        widget.background = "bg.png"
        widget.foreground = "fg.png"
        widget.rotateCenterX = 120
        widget.rotateCenterY = 130
        widget.arcStartAngle = -91.5
        widget.arcEndAngle = 300.25
        widget.arcLineWidth = 11
        widget.rangeMin = -10
        widget.rangeMax = 500
        widget.pointerImage = "ptr.bmp"
        widget.pointerAnchorX = 0.75
        widget.pointerAnchorY = 0.25
        widget.pointList = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.9)]
        widget.lineWidth = 9
        widget.colorR = 12
        widget.colorG = 34
        widget.colorB = 56

        let data = try JSONEncoder().encode(widget)
        let decoded = try JSONDecoder().decode(WidgetItem.self, from: data)

        XCTAssertEqual(widget, decoded, "all properties must survive encode/decode")
    }

    func testWidgetItemFrameMath() {
        var widget = WidgetItem(kind: .image, name: "Frame")
        widget.x = 10
        widget.y = 20
        widget.width = 30
        widget.height = 40

        XCTAssertEqual(widget.frame, CGRect(x: 10, y: 20, width: 30, height: 40))
    }
}