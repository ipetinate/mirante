import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Mirante

@MainActor
final class EditorStateExtendedTests: XCTestCase {

    private func makePGN(width: Int, height: Int) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mirante-ext-\(UUID().uuidString).png")
        try (data as Data).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func threeWidgetEditor() -> (editor: EditorState, a: WidgetItem, b: WidgetItem, c: WidgetItem) {
        let editor = EditorState()
        var a = WidgetItem(kind: .image, name: "A")
        a.id = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!
        var b = WidgetItem(kind: .image, name: "B")
        b.id = UUID(uuidString: "B0000000-0000-0000-0000-00000000000B")!
        var c = WidgetItem(kind: .image, name: "C")
        c.id = UUID(uuidString: "C0000000-0000-0000-0000-00000000000C")!
        editor.project.widgets = [a, b, c]
        return (editor, a, b, c)
    }

    func testAddWidgetKindsStayInScreenBounds() {
        let editor = EditorState()
        let device = editor.project.device

        for kind in WidgetKind.allCases {
            editor.addWidget(kind: kind)
            let widget = try! XCTUnwrap(editor.activeWidgets.last)
            XCTAssertEqual(widget.kind, kind)
            XCTAssertGreaterThan(widget.width, 0)
            XCTAssertGreaterThan(widget.height, 0)
            XCTAssertGreaterThanOrEqual(widget.x, 0)
            XCTAssertGreaterThanOrEqual(widget.y, 0)
            XCTAssertLessThanOrEqual(widget.x + widget.width, device.width)
            XCTAssertLessThanOrEqual(widget.y + widget.height, device.height)
        }
        XCTAssertEqual(editor.activeWidgets.count, WidgetKind.allCases.count)
    }

    func testAddWidgetShapeSpecificDefaults() {
        let editor = EditorState()
        XCTAssertEqual(editor.project.device.id, "xiaomi_color")

        editor.addWidget(kind: .image)
        var widget = try! XCTUnwrap(editor.activeWidgets.last)
        XCTAssertEqual(widget.width, min(120, editor.project.device.width / 3))
        XCTAssertEqual(widget.height, min(120, editor.project.device.height / 4))

        editor.addWidget(kind: .digitalNumber)
        widget = try! XCTUnwrap(editor.activeWidgets.last)
        XCTAssertEqual(widget.height, 64)
        XCTAssertEqual(widget.digits, 2)
        XCTAssertEqual(widget.valueSourceID, "8")

        editor.addWidget(kind: .analog)
        widget = try! XCTUnwrap(editor.activeWidgets.last)
        XCTAssertEqual(widget.width, 200)
        XCTAssertEqual(widget.height, 200)
        XCTAssertEqual(widget.x, (editor.project.device.width - 200) / 2)

        editor.addWidget(kind: .arc)
        widget = try! XCTUnwrap(editor.activeWidgets.last)
        XCTAssertEqual(widget.width, 200)
        XCTAssertEqual(widget.height, 200)
        XCTAssertEqual(widget.valueSourceID, "23")

        editor.addWidget(kind: .imageList)
        widget = try! XCTUnwrap(editor.activeWidgets.last)
        XCTAssertEqual(widget.indexSourceID, "10")

        editor.addWidget(kind: .pointer)
        widget = try! XCTUnwrap(editor.activeWidgets.last)
        XCTAssertEqual(widget.valueSourceID, "8")
    }

    func testAddWidgetUniquifiesNames() {
        let editor = EditorState()
        editor.addWidget(kind: .image)
        editor.addWidget(kind: .image)
        XCTAssertEqual(editor.activeWidgets.map(\.name), ["Image", "Image 2"])
    }

    func testDeleteSelectedRemovesWidgetAndSelection() {
        let editor = EditorState()
        editor.addWidget(kind: .image)
        XCTAssertFalse(editor.activeWidgets.isEmpty)

        editor.deleteSelected()

        XCTAssertTrue(editor.activeWidgets.isEmpty)
        XCTAssertNil(editor.selection)
        XCTAssertTrue(editor.canUndo)

        editor.deleteSelected()
        XCTAssertTrue(editor.canUndo, "delete without selection must be a no-op")
    }

    func testCopySetsClipboard() {
        let editor = EditorState()
        editor.addWidget(kind: .image)
        let widget = try! XCTUnwrap(editor.selectedWidget)

        editor.copySelected()

        XCTAssertEqual(editor.clipboard, widget)
    }

    func testCutCopiesAndRemovesSelection() {
        let editor = EditorState()
        editor.addWidget(kind: .image)
        let widget = try! XCTUnwrap(editor.selectedWidget)

        editor.cutSelected()

        XCTAssertEqual(editor.clipboard, widget)
        XCTAssertTrue(editor.activeWidgets.isEmpty)
        XCTAssertNil(editor.selection)
        XCTAssertTrue(editor.canUndo)
    }

    func testPasteAddsOffsetAndUniquifiesName() {
        let editor = EditorState()
        editor.addWidget(kind: .image)
        let widget = try! XCTUnwrap(editor.selectedWidget)

        editor.copySelected()
        editor.paste()

        XCTAssertEqual(editor.activeWidgets.count, 2)
        let pasted = try! XCTUnwrap(editor.activeWidgets.last)
        XCTAssertNotEqual(pasted.id, widget.id)
        XCTAssertEqual(pasted.name, "Image 2")
        XCTAssertEqual(pasted.x, widget.x + 16)
        XCTAssertEqual(pasted.y, widget.y + 16)
        XCTAssertNotNil(editor.clipboard)
        XCTAssertEqual(editor.clipboard?.id, pasted.id, "clipboard tracks the pasted copy")

        editor.paste()
        XCTAssertEqual(editor.activeWidgets.count, 3)
        XCTAssertEqual(editor.activeWidgets.last?.name, "Image 3")
        XCTAssertEqual(editor.activeWidgets.last?.x, widget.x + 32)
        XCTAssertEqual(editor.activeWidgets.last?.y, widget.y + 32)
    }

    func testPasteWithoutClipboardDoesNothing() {
        let editor = EditorState()
        XCTAssertNil(editor.clipboard)

        editor.paste()

        XCTAssertTrue(editor.activeWidgets.isEmpty)
        XCTAssertFalse(editor.canUndo)
    }

    func testDuplicateSelectedAddsCopy() {
        let editor = EditorState()
        editor.addWidget(kind: .image)
        let widget = try! XCTUnwrap(editor.selectedWidget)

        editor.duplicateSelected()

        XCTAssertEqual(editor.activeWidgets.count, 2)
        let copy = try! XCTUnwrap(editor.activeWidgets.last)
        XCTAssertNotEqual(copy.id, widget.id)
        XCTAssertEqual(copy.kind, widget.kind)
        XCTAssertEqual(copy.name, "Image 2")
        XCTAssertEqual(copy.x, widget.x + 16)
        XCTAssertEqual(copy.y, widget.y + 16)
        XCTAssertEqual(editor.selection, copy.id)
    }

    func testMoveSelectionFront() {
        let (editor, a, b, c) = threeWidgetEditor()
        editor.selection = b.id
        editor.moveSelection(layerDirection: .front)
        XCTAssertEqual(editor.activeWidgets.map(\.id), [a.id, c.id, b.id])
    }

    func testMoveSelectionBack() {
        let (editor, a, b, c) = threeWidgetEditor()
        editor.selection = c.id
        editor.moveSelection(layerDirection: .back)
        XCTAssertEqual(editor.activeWidgets.map(\.id), [c.id, a.id, b.id])
    }

    func testMoveSelectionForward() {
        let (editor, a, b, c) = threeWidgetEditor()
        editor.selection = a.id
        editor.moveSelection(layerDirection: .forward)
        XCTAssertEqual(editor.activeWidgets.map(\.id), [b.id, a.id, c.id])
    }

    func testMoveSelectionBackward() {
        let (editor, a, b, c) = threeWidgetEditor()
        editor.selection = b.id
        editor.moveSelection(layerDirection: .backward)
        XCTAssertEqual(editor.activeWidgets.map(\.id), [b.id, a.id, c.id])
    }

    func testMoveSelectionNoOpAtEdge() {
        let (editor, a, b, c) = threeWidgetEditor()

        editor.selection = c.id
        editor.moveSelection(layerDirection: .front)
        XCTAssertFalse(editor.canUndo, "already frontmost must not record anything")
        XCTAssertEqual(editor.activeWidgets.map(\.id), [a.id, b.id, c.id])

        editor.selection = a.id
        editor.moveSelection(layerDirection: .back)
        XCTAssertFalse(editor.canUndo, "already backmost must not record anything")
        XCTAssertEqual(editor.activeWidgets.map(\.id), [a.id, b.id, c.id])
    }

    func testUpdateOnlyRecordsWhenChanged() {
        let editor = EditorState()
        editor.addWidget(kind: .image)
        XCTAssertTrue(editor.canUndo)

        let alpha = editor.selectedWidget?.alpha ?? 0
        editor.update({ $0.alpha = alpha }, label: "Opacity")
        XCTAssertEqual(editor.undoLevels, 1, "no-op update must not push an undo entry")

        let name = editor.selectedWidget?.name ?? ""
        editor.update({ $0.name = name }, label: "Rename")
        XCTAssertEqual(editor.undoLevels, 1)

        editor.update({ $0.alpha = 5 }, label: "Opacity")
        XCTAssertEqual(editor.undoLevels, 2, "real change must push an undo entry")
        XCTAssertEqual(editor.selectedWidget?.alpha, 5)
    }

    func testUpdateWithoutSelectionIsNoOp() {
        let editor = EditorState()
        editor.update({ $0.width = 999 }, label: "Width")
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(editor.activeWidgets.isEmpty)
    }

    func testBeginEndGestureCoalescesIntoOneUndoStep() {
        let editor = EditorState()
        editor.addWidget(kind: .image)
        editor.update({ $0.alpha = 50 }, label: "Opacity")
        XCTAssertEqual(editor.undoLevels, 2)

        editor.beginGesture()
        editor.update({ $0.alpha = 80 }, label: "Opacity")
        editor.update({ $0.alpha = 120 }, label: "Opacity")
        editor.update({ $0.alpha = 160 }, label: "Opacity")
        editor.endGesture()

        XCTAssertEqual(editor.undoLevels, 3, "the whole gesture must collapse into one undo step")
        XCTAssertEqual(editor.selectedWidget?.alpha, 160)

        editor.undo()
        XCTAssertEqual(editor.selectedWidget?.alpha, 50, "undo must revert to the value at gesture start")
        XCTAssertEqual(editor.undoLevels, 2)
        XCTAssertEqual(editor.redoLevels, 1)
        XCTAssertTrue(editor.canRedo)

        editor.redo()
        XCTAssertEqual(editor.selectedWidget?.alpha, 160)
        XCTAssertEqual(editor.redoLevels, 0)
        XCTAssertFalse(editor.canRedo)
    }

    func testImportImageDoesNotConsumePendingRequest() throws {
        let editor = EditorState()
        editor.requestImageImport(kind: .imageList)
        XCTAssertNotNil(editor.imageImportRequest)
        let png = try makePGN(width: 200, height: 100)

        let id = try XCTUnwrap(editor.importImage(at: png, kind: .imageList))

        XCTAssertNotNil(editor.imageImportRequest, "import must not clear the picker request (the picker owns it)")
        XCTAssertEqual(editor.imageImportRequest?.kind, .imageList)
        let widget = try XCTUnwrap(editor.activeWidgets.first { $0.id == id })
        XCTAssertEqual(widget.kind, .imageList)
        XCTAssertEqual(widget.bitmapList, [png.lastPathComponent], "imageList import must populate bitmapList")
        XCTAssertEqual(widget.bitmap, png.lastPathComponent)
    }
}