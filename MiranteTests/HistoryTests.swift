import Foundation
import XCTest

@testable import Mirante

@MainActor
final class HistoryTests: XCTestCase {

    private func makeEditor() -> EditorState {
        EditorState()
    }

    private func widget(_ kind: WidgetKind, name: String) -> WidgetItem {
        WidgetItem(kind: kind, name: name)
    }

    func testUndoRevertsLastChangeAndRedoReapplies() {
        let editor = makeEditor()
        let history = History()

        let one = widget(.image, name: "One")
        let two = widget(.image, name: "Two")

        history.execute(AddWidgetCommand(widget: one, index: 0), state: editor)
        XCTAssertEqual(editor.activeWidgets, [one])
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.redoCount, 0)

        history.execute(AddWidgetCommand(widget: two, index: 1), state: editor)
        XCTAssertEqual(editor.activeWidgets, [one, two])
        XCTAssertEqual(history.undoCount, 2)

        XCTAssertTrue(history.undo(state: editor))
        XCTAssertEqual(editor.activeWidgets, [one])
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.redoCount, 1)

        XCTAssertTrue(history.undo(state: editor))
        XCTAssertTrue(editor.activeWidgets.isEmpty)
        XCTAssertEqual(history.undoCount, 0)
        XCTAssertEqual(history.redoCount, 2)
        XCTAssertFalse(history.undo(state: editor), "undo on empty stack must return false")

        XCTAssertTrue(history.redo(state: editor))
        XCTAssertEqual(editor.activeWidgets, [one])
        XCTAssertTrue(history.redo(state: editor))
        XCTAssertEqual(editor.activeWidgets, [one, two])
        XCTAssertEqual(history.redoCount, 0)

        XCTAssertFalse(history.redo(state: editor), "redo on empty stack must return false")
    }

    func testUndoRedoLabels() {
        let editor = makeEditor()
        let history = History()

        history.execute(AddWidgetCommand(widget: widget(.image, name: "A"), index: 0), state: editor)
        XCTAssertEqual(history.undoLabel, "Add Widget")
        XCTAssertNil(history.redoLabel)

        _ = history.undo(state: editor)
        XCTAssertEqual(history.redoLabel, "Add Widget")
        XCTAssertNil(history.undoLabel)
    }

    func testCoalescingGroupsUpdatesIntoOneUndoStep() {
        let editor = makeEditor()
        let history = History()

        var base = widget(.image, name: "W")
        base.alpha = 255
        var v1 = base
        v1.alpha = 100
        var v2 = v1
        v2.alpha = 200
        editor.project.widgets = [base]

        history.beginCoalescing()
        history.recordModify(label: "Opacity", before: base, after: v1, state: editor)
        history.recordModify(label: "Opacity", before: v1, after: v2, state: editor)
        XCTAssertEqual(editor.activeWidgets, [v2])
        XCTAssertEqual(history.undoCount, 1, "coalesced run must occupy exactly one undo step")
        history.endCoalescing()

        XCTAssertTrue(history.undo(state: editor))
        XCTAssertEqual(editor.activeWidgets, [base], "one undo must revert the whole gesture")
        XCTAssertEqual(history.undoCount, 0)
        XCTAssertEqual(history.redoCount, 1)

        XCTAssertTrue(history.redo(state: editor))
        XCTAssertEqual(editor.activeWidgets, [v2])
    }

    func testCoalescingAcrossDifferentWidgetsPushesSeparateSteps() {
        let editor = makeEditor()
        let history = History()

        var a = widget(.image, name: "A")
        var a1 = a
        a1.x = 5
        var b = widget(.image, name: "B")
        var b1 = b
        b1.y = 9
        editor.project.widgets = [a, b]

        history.beginCoalescing()
        history.recordModify(label: "M", before: a, after: a1, state: editor)
        history.recordModify(label: "M", before: b, after: b1, state: editor)
        history.endCoalescing()

        XCTAssertEqual(history.undoCount, 2, "changes to different widgets must not merge")
        XCTAssertEqual(history.undoLabel, "M")
    }

    func testRecordModifyIgnoresUnchangedValues() {
        let editor = makeEditor()
        let history = History()

        let w = widget(.image, name: "W")
        editor.project.widgets = [w]

        history.recordModify(label: "No-op", before: w, after: w, state: editor)

        XCTAssertEqual(history.undoCount, 0, "an unchanged write must not be recorded")
        XCTAssertEqual(editor.activeWidgets, [w])
    }

    func testExecuteClearsRedoStack() {
        let editor = makeEditor()
        let history = History()
        history.execute(AddWidgetCommand(widget: widget(.image, name: "A"), index: 0), state: editor)
        _ = history.undo(state: editor)
        XCTAssertEqual(history.redoCount, 1)

        history.execute(AddWidgetCommand(widget: widget(.image, name: "B"), index: 1), state: editor)

        XCTAssertEqual(history.redoCount, 0, "a fresh command must invalidate the redo stack")
        XCTAssertEqual(history.undoCount, 1)
    }
}