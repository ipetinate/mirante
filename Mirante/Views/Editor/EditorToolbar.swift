import SwiftUI

struct EditorToolbar: ToolbarContent {
    @Environment(EditorState.self) private var editor

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
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
                Label("Add Widget", systemImage: "plus")
            }
            .help("Add a widget")

            Button {
                editor.deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(editor.selectedWidget == nil)
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Delete selected widget")

            Menu {
                Button {
                    editor.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!editor.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                Button {
                    editor.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!editor.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            } label: {
                Label("History", systemImage: "arrow.uturn.backward")
            }
            .help("Undo and redo edits")

            Button {
                editor.fitWidgetToScreen()
            } label: {
                Label("Fit to Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(editor.selectedWidget == nil)
            .help("Fit the selected widget to the screen and center it")

            Menu {
                Button("Copy") { editor.copySelected() }
                    .disabled(editor.selectedWidget == nil)
                Button("Cut") { editor.cutSelected() }
                    .disabled(editor.selectedWidget == nil)
                Button("Paste") { editor.paste() }
                    .disabled(editor.clipboard == nil)
                Button("Duplicate") { editor.duplicateSelected() }
                    .disabled(editor.selectedWidget == nil)
                    .keyboardShortcut("d", modifiers: .command)
            } label: {
                Label("Edit", systemImage: "clipboard")
            }
            .help("Copy, cut, paste and duplicate widgets")

            Toggle(isOn: Binding(
                get: { editor.isAODActive },
                set: { editor.isAODActive = $0; editor.selection = nil }
            )) {
                Label("AOD", systemImage: "sun.max")
            }
            .accessibilityLabel("Always-On Display")
            .help("Edit the always-on-display layer")

            Toggle(isOn: Binding(
                get: { editor.showGrid },
                set: { editor.showGrid = $0 }
            )) {
                Label("Grid", systemImage: "grid")
            }
            .help("Toggle the layout grid")

            Menu {
                Button("Zoom In") { editor.zoom = min(4, editor.zoom * 1.25) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(editor.zoom >= 4)
                Button("Zoom Out") { editor.zoom = max(0.25, editor.zoom / 1.25) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(editor.zoom <= 0.25)
                Button("Actual Size") { editor.zoom = 1 }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(abs(editor.zoom - 1) < 0.001)
            } label: {
                Label("Zoom", systemImage: "magnifyingglass")
            }
            .help("Zoom the canvas")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            PublishButton()
            ExportButton()
        }
    }

    }

struct PublishButton: View {
    @Environment(EditorState.self) private var editor
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Label("Publish", systemImage: "arrow.up.circle")
        }
        .help("Publish the watch face to your store")
        .sheet(isPresented: $showSheet) {
            PublishSheet()
        }
    }
}

struct ExportButton: View {
    @Environment(EditorState.self) private var editor
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Export the watch face project")
        .sheet(isPresented: $showSheet) {
            ExportSheet()
        }
    }
}