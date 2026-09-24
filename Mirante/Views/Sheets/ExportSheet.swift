import SwiftUI

struct ExportSheet: View {
    @Environment(EditorState.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var exportName = ""
    @State private var includeAOD: Bool?
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    TextField("Name", text: $exportName)
                    LabeledContent("Format") {
                        Text("FPRJ (XML)")
                    }
                    LabeledContent("Device") {
                        Text(editor.project.device.name)
                    }
                    if editor.project.usesAOD {
                        Toggle("Include AOD screen", isOn: Binding(
                            get: { includeAOD ?? true },
                            set: { includeAOD = $0 }
                        ))
                    }
                }

                Section("Source preview") {
                    ScrollView {
                        Text(FprjExporter.export(previewProject))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }

                Section {
                    Text("Compiling to an installable .face file requires the closed Windows toolchain and is not available in this app. The exported .fprj can be compiled later on a PC.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
                #if os(iOS)
                .scrollDismissesKeyboard(.immediately)
                #endif
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .help("Cancel the export")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let exportURL {
                        ShareLink(
                            item: exportURL,
                            preview: SharePreview(exportFileName, image: Image(systemName: "applewatch.watchface"))
                        ) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .help("Share the exported project file")
                    }
                }
            }
            .onAppear {
                if exportName.isEmpty { exportName = editor.project.name }
                prepareExport()
            }
            .onChange(of: exportName) { _, _ in prepareExport() }
            .onChange(of: includeAOD) { _, _ in prepareExport() }
            .onChange(of: editor.project) { _, _ in prepareExport() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private func prepareExport() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(exportFileName)
        let data = Data(FprjExporter.export(previewProject).utf8)
        do {
            try data.write(to: tempURL)
            exportURL = tempURL
        } catch {
            exportURL = nil
        }
    }

    private var previewProject: WatchFaceProject {
        var project = editor.project
        if includeAOD == false { project.usesAOD = false }
        return project
    }

    private var exportFileName: String {
        let base = exportName.isEmpty ? editor.project.name : exportName
        let safe = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).fprj"
    }
}