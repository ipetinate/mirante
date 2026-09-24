import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders a `WatchFaceProject` to a PNG cover using the same live preview
/// view shown everywhere else in the app. Used to attach `preview.png` when
/// publishing a face to the store.
enum PreviewRenderer {
    /// Returns a PNG snapshot of the face at the device's preview size.
    /// `editor` is injected only to satisfy LivePreviewView's environment; the
    /// preview passes concrete data so nothing is read from the live project.
    @MainActor
    static func renderPNG(_ project: WatchFaceProject, editor: EditorState) -> Data? {
        let target = project.device.previewSize
        let renderer = ImageRenderer(
            content: LivePreviewView(
                widgets: project.widgets,
                screen: project.screenSize,
                device: project.device,
                images: project.images
            )
            .environment(editor)
            .frame(width: target.width, height: target.height)
        )
        renderer.scale = 3

        #if os(macOS)
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return renderer.uiImage?.pngData()
        #endif
    }
}