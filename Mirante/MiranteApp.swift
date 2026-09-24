import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct MiranteApp: App {
    @State private var editor = EditorState()
    @State private var bandTransport = BandTransport()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(editor)
                .environment(bandTransport)
        }
        #if os(macOS)
        .defaultSize(
            width: NSScreen.main?.visibleFrame.width ?? 1440,
            height: NSScreen.main?.visibleFrame.height ?? 900
        )
        .restorationBehavior(.disabled)
        #endif
        .commands {
            #if os(macOS)
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("New Watchface…") { editor.showNewProjectSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            #endif
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { editor.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!editor.canUndo)
                Button("Redo") { editor.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!editor.canRedo)
            }
        }
    }
}
