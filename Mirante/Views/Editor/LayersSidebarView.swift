import SwiftUI

struct LayersSidebarView: View {
    @Environment(EditorState.self) private var editor
    @State private var renameTarget: UUID?
    @State private var renameText = ""

    var body: some View {
        @Bindable var editor = editor

        VStack(spacing: 0) {
            addBar
            Divider()
            List(selection: $editor.selection) {
            Section {
                ForEach(Array(displayWidgets.enumerated()), id: \.element.id) { displayRow, widget in
                    LayerRow(widget: widget, row: displayRow) { items in
                        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                        editor.moveWidget(id, toDisplayRow: displayRow)
                        return true
                    }
                    .tag(widget.id)
                    .contextMenu {
                        Button("Rename…") {
                            renameTarget = widget.id
                            renameText = widget.name
                        }
                        Button("Copy") {
                            editor.selection = widget.id
                            editor.copySelected()
                        }
                        Button("Cut") {
                            editor.selection = widget.id
                            editor.cutSelected()
                        }
                        Button("Duplicate") {
                            editor.selection = widget.id
                            editor.duplicateSelected()
                        }
                        Button("Delete", role: .destructive) {
                            editor.selection = widget.id
                            editor.deleteSelected()
                        }
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        let widget = displayWidgets[offset]
                        editor.selection = widget.id
                        editor.deleteSelected()
                    }
                }
            } header: {
                Text(editor.isAODActive ? "AOD Widgets" : "Widgets")
            } footer: {
                Text("The top row draws in front. Drag a row to reorder. Right-click to rename.")
            }
            }
            .listStyle(.sidebar)
            .overlay {
                if editor.activeWidgets.isEmpty {
                    ContentUnavailableView(
                        "No Widgets",
                        systemImage: "square.grid.2x2",
                        description: Text("Use the Add button above to create your first widget.")
                    )
                }
            }
            .alert(
                "Rename Widget",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let target = renameTarget {
                        editor.renameWidget(target, to: renameText)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a new name for the selected widget. The name is used in the exported face.")
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 12) {
            Label("Add Widget", systemImage: "plus.circle.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(WidgetKind.allCases.filter { $0.isAddable(for: editor.project.format) }) { kind in
                    Button {
                        if kind == .image || kind == .imageList {
                            editor.requestImageImport(kind: kind)
                        } else {
                            editor.addWidget(kind: kind)
                        }
                    } label: {
                        Label(kind.displayName, systemImage: kind.systemImage)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Add widget")
            .help("Add a widget")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
/// Reversed so the row on TOP is the frontmost widget (drawn on top).
    private var displayWidgets: [WidgetItem] {
        Array(editor.activeWidgets).reversed()
    }
}

struct LayerRow: View {
    let widget: WidgetItem
    let row: Int
    let onDrop: ([String]) -> Bool
    @State private var isDropTarget = false

    var body: some View {
        Label {
            HStack {
                Text(widget.name)
                    .lineLimit(1)
                Spacer()
                Text("\(row + 1)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: widget.kind.systemImage)
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(widget.name)
        .accessibilityValue("Layer \(row + 1)")
        .contentShape(Rectangle())
        .draggable(widget.id.uuidString) {
            DragPreviewContent(widget: widget)
        }
        .dropDestination(for: String.self) { items, _ in
            onDrop(items)
        } isTargeted: { isTargeted in
            isDropTarget = isTargeted
        }
        .listRowBackground(isDropTarget ? Color.accentColor.opacity(0.12) : nil)
    }
}

private struct DragPreviewContent: View {
    let widget: WidgetItem

    var body: some View {
        Label {
            Text(widget.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: widget.kind.systemImage)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}