import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Mirante

@MainActor
final class EditorStateTests: XCTestCase {

    private var editor: EditorState!
    private var imageURL: URL!

    override func setUp() async throws {
        editor = EditorState()
        let size = CGSize(width: 200, height: 100)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 100,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let img = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        imageURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mirante-test-\(UUID().uuidString).png")
        try (data as Data).write(to: imageURL)
    }

    override func tearDown() async throws {
        if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
        editor = nil
    }

    func testImportImageRequiresNoPendingRequest() throws {
        // Regression for "picker selects an image but nothing is added":
        // the picker dismisses and clears the request BEFORE the completion runs.
        editor.requestImageImport(kind: .image)
        editor.imageImportRequest = nil

        let id = editor.importImage(at: imageURL, kind: .image)

        let idValue = try XCTUnwrap(id)
        let widget = editor.activeWidgets.first { $0.id == idValue }
        XCTAssertNotNil(widget)
        XCTAssertEqual(widget?.name, imageURL.deletingPathExtension().lastPathComponent)
        XCTAssertNotNil(editor.runtimeImages[idValue], "real preview data must be registered")
    }

    func testImportImageFitsWithinScreenWidthAndCenters() throws {
        let screen = editor.project.screenSize
        let id = try XCTUnwrap(editor.importImage(at: imageURL, kind: .image))
        let widget = try XCTUnwrap(editor.activeWidgets.first { $0.id == id })

        XCTAssertGreaterThanOrEqual(widget.width, 4)
        XCTAssertLessThanOrEqual(widget.width, Int(screen.width.rounded()))
        XCTAssertLessThanOrEqual(widget.height, Int(screen.height.rounded()))
        XCTAssertEqual(widget.x, max(0, (Int(screen.width) - widget.width) / 2))
        XCTAssertEqual(widget.y, max(0, (Int(screen.height) - widget.height) / 2))
        let scale = CGFloat(widget.width) / 200
        XCTAssertEqual(Double(widget.height), (100 * Double(scale)).rounded(), "aspect ratio must be preserved")
    }

    func testImportImageNeverOverflowsScreenBounds() throws {
        // Portrait band screen (336x480) receiving a very tall image.
        let device = try XCTUnwrap(Device.find("xiaomi_band_10_pro"))
        let band = EditorState(project: .new(name: "Tall", device: device))

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 336, height: 1000,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 336, height: 1000))
        guard let img = ctx.makeImage() else {
            return XCTFail("could not make tall image")
        }
        let tallPNG = NSMutableData()
        let dest = CGImageDestinationCreateWithData(tallPNG, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        let tallURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mirante-tall-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tallURL) }
        try (tallPNG as Data).write(to: tallURL)

        let id = try XCTUnwrap(band.importImage(at: tallURL, kind: .image))
        let widget = try XCTUnwrap(band.activeWidgets.first { $0.id == id })

        XCTAssertGreaterThanOrEqual(widget.x, 0)
        XCTAssertGreaterThanOrEqual(widget.y, 0)
        XCTAssertLessThanOrEqual(widget.x + widget.width, 336, "right edge must stay inside the screen")
        XCTAssertLessThanOrEqual(widget.y + widget.height, 480, "bottom edge must stay inside the screen")
        XCTAssertEqual(widget.y, 0, "full-height image sits at the top")
        // 336x1000 → scaled by min(336/336, 480/1000) = 0.48 → width ≈ 161
        XCTAssertEqual(widget.height, 480)
        XCTAssertEqual(widget.width, Int((CGFloat(336) * 0.48).rounded()))
    }

    func testImportImageListPopulatesBitmapList() throws {
        let id = try XCTUnwrap(editor.importImage(at: imageURL, kind: .imageList))
        let widget = try XCTUnwrap(editor.activeWidgets.first { $0.id == id })
        XCTAssertEqual(widget.bitmapList, [imageURL.lastPathComponent])
    }

    func testMoveWidgetToDisplayRowZeroPutsItFrontmost() throws {
        editor.addWidget(kind: .image)
        editor.addWidget(kind: .image)
        editor.addWidget(kind: .image)
        let ids = editor.activeWidgets.map(\.id)
        let first = try XCTUnwrap(ids.first)

        editor.moveWidget(first, toDisplayRow: 0)

        XCTAssertEqual(editor.activeWidgets.last?.id, first, "top of layer list (row 0) must render frontmost")
        XCTAssertEqual(editor.activeWidgets.count, ids.count)
    }

    func testMoveWidgetToBackRowZeroPutsItAtBottom() throws {
        editor.addWidget(kind: .image)
        editor.addWidget(kind: .image)
        editor.addWidget(kind: .image)
        let ids = editor.activeWidgets.map(\.id)
        let last = try XCTUnwrap(ids.last)

        editor.moveWidget(last, toDisplayRow: ids.count - 1)

        XCTAssertEqual(editor.activeWidgets.first?.id, last, "bottom of layer list must render backmost")
    }

    func testRepositionAllowsPositioningOffScreen() throws {
        let id = try XCTUnwrap(editor.importImage(at: imageURL, kind: .image))

        editor.repositionWidget(id, toX: 10_000, y: -5_000)

        let moved = try XCTUnwrap(editor.activeWidgets.first { $0.id == id })
        XCTAssertEqual(moved.x, 10_000, "x position must not be clamped to the screen")
        XCTAssertEqual(moved.y, -5_000, "y position must not be clamped to the screen")
    }

    func testFitWidgetToScreenFillsEntireScreen() throws {
        let id = try XCTUnwrap(editor.importImage(at: imageURL, kind: .image))
        let screen = editor.project.screenSize
        editor.selection = id

        editor.fitWidgetToScreen()

        let fitted = try XCTUnwrap(editor.activeWidgets.first { $0.id == id })
        XCTAssertEqual(fitted.x, 0)
        XCTAssertEqual(fitted.y, 0)
        XCTAssertEqual(fitted.width, Int(screen.width.rounded()))
        XCTAssertEqual(fitted.height, Int(screen.height.rounded()))
    }

    func testRequestImageImportSetsRequest() {
        XCTAssertNil(editor.imageImportRequest)
        editor.requestImageImport(kind: .imageList)
        XCTAssertEqual(editor.imageImportRequest?.kind, .imageList)
        XCTAssertEqual(editor.imageImportRequest?.source, .files, "plain request must default to the Files picker")
    }

    func testRequestImageForExistingWidgetSetsRequest() {
        XCTAssertNil(editor.imageImportRequest)
        let id = UUID()
        editor.requestImage(for: .setFilename(widgetID: id, keyPath: \.bitmap), source: .cameraRoll)
        XCTAssertEqual(editor.imageImportRequest?.source, .cameraRoll)
        XCTAssertEqual(editor.imageImportRequest?.kind, .image)
    }

    func testRequestBasedImportSetsFilenameOnExistingWidget() throws {
        editor.addWidget(kind: .image)
        let id = try XCTUnwrap(editor.selectedWidget?.id)
        let data = try Data(contentsOf: imageURL)
        editor.requestImage(for: .setFilename(widgetID: id, keyPath: \.bitmap), source: .files)
        let request = try XCTUnwrap(editor.imageImportRequest)

        let result = editor.importImage(data: data, fileName: "roll-abc.png", request: request)

        XCTAssertEqual(result, id)
        let widget = try XCTUnwrap(editor.activeWidgets.first { $0.id == id })
        XCTAssertEqual(widget.bitmap, "roll-abc.png")
        XCTAssertNotNil(editor.runtimeImages[id], "live preview data must be registered")

        XCTAssertNotNil(editor.imageImportRequest, "import must not clear the picker request (the picker owns it)")
    }

    func testRequestBasedImportAppendsImageListItem() throws {
        editor.addWidget(kind: .imageList)
        let id = try XCTUnwrap(editor.selectedWidget?.id)
        let data = try Data(contentsOf: imageURL)
        editor.requestImage(for: .appendListItem(widgetID: id), source: .cameraRoll)
        let request = try XCTUnwrap(editor.imageImportRequest)

        let result = editor.importImage(data: data, fileName: "roll-xyz.png", request: request)

        XCTAssertEqual(result, id)
        let widget = try XCTUnwrap(editor.activeWidgets.first { $0.id == id })
        XCTAssertEqual(widget.bitmapList, ["roll-xyz.png"])
    }
}