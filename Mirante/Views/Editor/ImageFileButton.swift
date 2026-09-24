import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import Photos
import PhotosUI
#endif

/// Lets the user pick an image for an image widget. On iOS it offers the
/// camera roll (with a photo-library permission prompt) or Files; on macOS it
/// uses the Files picker. The chosen file is registered for live preview and
/// then forwarded with `onPick` so the widget can record its filename.
struct ImageFileButton: View {
    @Environment(EditorState.self) private var editor
    let widgetID: UUID
    var label: String = "Choose…"
    let onPick: (URL) -> Void

    @State private var showImporter = false
    #if os(iOS)
    @State private var showPhotoPicker = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var permissionDenied = false
    #endif

    var body: some View {
        #if os(iOS)
        Menu {
            Button {
                requestPhotoAccess()
            } label: {
                Label("Camera Roll…", systemImage: "photo.on.rectangle")
            }
            Button {
                showImporter = true
            } label: {
                Label("Files…", systemImage: "folder")
            }
        } label: {
            Text(label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            importPickerItem(item)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            if let data = try? Data(contentsOf: url) {
                editor.setImage(data, for: widgetID)
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
            onPick(url)
        }
        .alert("Photos Access Needed", isPresented: $permissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Mirante needs access to your photo library to pick images from the camera roll. You can grant it in Settings → Privacy → Photos.")
        }
        #else
        Button(label) {
            showImporter = true
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            if let data = try? Data(contentsOf: url) {
                editor.setImage(data, for: widgetID)
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
            onPick(url)
        }
        #endif
    }

    #if os(iOS)
    private func requestPhotoAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                switch status {
                case .authorized, .limited:
                    pickerItem = nil
                    showPhotoPicker = true
                default:
                    permissionDenied = true
                }
            }
        }
    }

    private func importPickerItem(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  !data.isEmpty else { return }
            let ext = imageExtension(for: data)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("roll-\(UUID().uuidString.prefix(6))")
                .appendingPathExtension(ext)
            try? data.write(to: temp)
            editor.setImage(data, for: widgetID)
            onPick(temp)
        }
    }

    private func imageExtension(for data: Data) -> String {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let gif: [UInt8] = [0x47, 0x49, 0x46]
        let bmp: [UInt8] = [0x42, 0x4D]
        let head = Array(data.prefix(4))
        if head.starts(with: png) { return "png" }
        if head.starts(with: gif) { return "gif" }
        if head.starts(with: bmp) { return "bmp" }
        return "jpg"
    }
    #endif
}