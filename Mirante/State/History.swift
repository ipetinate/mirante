import Foundation

@MainActor
protocol EditorCommand {
    var label: String { get }
    func apply(to state: EditorState)
    func revert(from state: EditorState)
}

struct AddWidgetCommand: EditorCommand {
    let label = "Add Widget"
    let widget: WidgetItem
    let index: Int

    func apply(to state: EditorState) {
        var widgets = state.activeWidgets
        let idx = min(index, widgets.count)
        widgets.insert(widget, at: idx)
        state.replaceActiveWidgets(widgets)
        state.selection = widget.id
    }

    func revert(from state: EditorState) {
        var widgets = state.activeWidgets
        widgets.removeAll { $0.id == widget.id }
        state.replaceActiveWidgets(widgets)
        if state.selection == widget.id { state.selection = nil }
    }
}

struct DeleteWidgetCommand: EditorCommand {
    let label = "Delete Widget"
    let widget: WidgetItem
    let index: Int

    func apply(to state: EditorState) {
        var widgets = state.activeWidgets
        widgets.removeAll { $0.id == widget.id }
        state.replaceActiveWidgets(widgets)
        if state.selection == widget.id { state.selection = nil }
    }

    func revert(from state: EditorState) {
        var widgets = state.activeWidgets
        let idx = min(index, widgets.count)
        widgets.insert(widget, at: idx)
        state.replaceActiveWidgets(widgets)
        state.selection = widget.id
    }
}

struct ModifyWidgetCommand: EditorCommand {
    let label: String
    let widgetID: UUID
    let before: WidgetItem
    let after: WidgetItem

    func apply(to state: EditorState) { write(after, to: state) }
    func revert(from state: EditorState) { write(before, to: state) }

    private func write(_ widget: WidgetItem, to state: EditorState) {
        var widgets = state.activeWidgets
        guard let idx = widgets.firstIndex(where: { $0.id == widgetID }) else { return }
        widgets[idx] = widget
        state.replaceActiveWidgets(widgets)
    }
}

struct ReorderWidgetCommand: EditorCommand {
    let label = "Reorder"
    let widgetID: UUID
    let from: Int
    let to: Int

    func apply(to state: EditorState) { move(state) }
    func revert(from state: EditorState) {
        let swapped = ReorderWidgetCommand(widgetID: widgetID, from: to, to: from)
        swapped.move(state)
    }

    private func move(_ state: EditorState) {
        var widgets = state.activeWidgets
        guard let idx = widgets.firstIndex(where: { $0.id == widgetID }),
              from < widgets.count, to < widgets.count else { return }
        let item = widgets.remove(at: idx)
        widgets.insert(item, at: to)
        state.replaceActiveWidgets(widgets)
    }
}

@MainActor
final class History {
    private var undoStack: [EditorCommand] = []
    private var redoStack: [EditorCommand] = []
    private let limit = 100

    var undoCount: Int { undoStack.count }
    var redoCount: Int { redoStack.count }
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    func execute(_ command: EditorCommand, state: EditorState) {
        command.apply(to: state)
        push(command)
        redoStack.removeAll()
    }

    @discardableResult
    func undo(state: EditorState) -> Bool {
        guard let command = undoStack.popLast() else { return false }
        command.revert(from: state)
        redoStack.append(command)
        return true
    }

    @discardableResult
    func redo(state: EditorState) -> Bool {
        guard let command = redoStack.popLast() else { return false }
        command.apply(to: state)
        push(command)
        return true
    }

    func beginCoalescing() {
        coalescing = true
        pendingBefore = nil
    }

    func endCoalescing() {
        coalescing = false
        pendingBefore = nil
    }

    private func push(_ command: EditorCommand) {
        undoStack.append(command)
        if undoStack.count > limit { undoStack.removeFirst() }
    }

    private var coalescing = false
    private var pendingBefore: (UUID, WidgetItem)?

    /// Records a property change. While coalescing (e.g. a slider drag) the
    /// change is committed to state and merged into a single undo step whose
    /// undo restores the value at gesture start.
    func recordModify(label: String, before: WidgetItem, after: WidgetItem, state: EditorState) {
        guard before != after else { return }

        let command = ModifyWidgetCommand(label: label, widgetID: after.id, before: before, after: after)
        command.apply(to: state)
        redoStack.removeAll()

        if coalescing,
           let pending = pendingBefore, pending.0 == after.id,
           let lastIdx = undoStack.indices.last,
           (undoStack[lastIdx] as? ModifyWidgetCommand)?.widgetID == after.id {
            undoStack[lastIdx] = ModifyWidgetCommand(
                label: label, widgetID: after.id, before: pending.1, after: after)
        } else {
            pendingBefore = (after.id, before)
            push(command)
        }
    }
}
