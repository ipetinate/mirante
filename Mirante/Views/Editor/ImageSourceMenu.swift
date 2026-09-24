import SwiftUI

/// A compact image source picker: "Camera Roll…" and "Files…" on iOS, just
/// "Files…" on macOS. It never presents a picker itself — it forwards a
/// destination through the editor's image import request so the root
/// `ContentView` presents the sheet-less Files importer or the PhotosPicker.
/// Presenting from the root avoids the iOS bug where a `.fileImporter` shown
/// from inside a `.sheet` silently stops opening again after a cancel.
struct ImageSourceMenu: View {
    @Environment(EditorState.self) private var editor
    let destination: ImageImportRequest.Destination
    var label: String = "Choose…"
    var systemImage: String = "photo"

    var body: some View {
        #if os(iOS)
        Menu {
            Button {
                editor.requestImage(for: destination, source: .cameraRoll)
            } label: {
                Label("Camera Roll…", systemImage: "photo.on.rectangle")
            }
            Button {
                editor.requestImage(for: destination, source: .files)
            } label: {
                Label("Files…", systemImage: "folder")
            }
        } label: {
            Label(label, systemImage: systemImage)
        }
        #else
        Button {
            editor.requestImage(for: destination, source: .files)
        } label: {
            Label(label, systemImage: systemImage)
        }
        #endif
    }
}