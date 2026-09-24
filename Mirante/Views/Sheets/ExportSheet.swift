import SwiftUI

struct ExportSheet: View {
    @Environment(EditorState.self) private var editor
    @Environment(BandTransport.self) private var transport
    @Environment(\.dismiss) private var dismiss

    @State private var exportName = ""
    @State private var includeAOD: Bool?
    @State private var exportURL: URL?
    @State private var binURL: URL?
    @State private var compileError: String?
    @State private var didCompile = false

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

                Section("Compiled (.bin)") {
                    if let binURL {
                        ShareLink(
                            item: binURL,
                            preview: SharePreview(compiledFileName, image: Image(systemName: "cube.fill"))
                        ) {
                            Label("Share Compiled .bin", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            installCompiled()
                        } label: {
                            Label("Install to Band", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .disabled(transport.isConnected ? transport.authKey == nil : false)
                    } else if didCompile {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Compiling…")
                        }
                    } else {
                        Button {
                            compile()
                        } label: {
                            Label("Build Compiled .bin", systemImage: "cube.fill")
                        }
                    }
                    if let compileError {
                        Text(compileError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Text("Builds the installable .bin in-app (magic header + face id), ready to send to a paired band or share.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                compile()
            }
            .onChange(of: exportName) { _, _ in prepareExport(); compile() }
            .onChange(of: includeAOD) { _, _ in prepareExport(); compile() }
            .onChange(of: editor.project) { _, _ in prepareExport(); compile() }
            .alert("Compile Failed", isPresented: Binding(
                get: { compileError != nil },
                set: { if !$0 { compileError = nil } }
            )) {
                Button("OK", role: .cancel) { compileError = nil }
            } message: {
                Text(compileError ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private func compile() {
        compileError = nil
        didCompile = true
        binURL = nil
        Task { @MainActor in
            // Defer the actual work off the main actor a beat so the
            // progress indicator renders on large projects.
            let data = (try? FaceBinCompiler.compile(previewProject)) ?? Data()
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard let binURL = writeTemporary(data, ext: "bin", name: compiledFileName) else {
                compileError = String(localized: "Could not write the compiled .bin.")
                return
            }
            self.binURL = binURL
            didCompile = false
        }
    }

    private func installCompiled() {
        guard let binURL else { return }
        guard let data = try? Data(contentsOf: binURL) else {
            compileError = String(localized: "The compiled .bin could not be read.")
            return
        }
        // Park it as a compiled face so the standard connect-then-install flow
        // can drive the send even when no band is connected right now.
        guard let face = CompiledFacesStore.add(copying: binURL, name: compiledFileName) else {
            compileError = String(localized: "Could not store the compiled .bin.")
            return
        }
        guard transport.isConnected else {
            editor.pendingInstallFace = face
            editor.showConnectionSheet = true
            dismiss()
            return
        }
        dismiss()
        sendCompiled(face, data: data)
    }

    private func sendCompiled(_ face: CompiledFace, data: Data) {
        guard let band = transport.connectedDevice else {
            compileError = TransportError.deviceNotPaired.errorDescription
            return
        }
        let device = band.deviceID.flatMap(Device.find) ?? Device.all[0]
        let validation = transport.validate(payload: data, for: device)
        guard validation.isOk else {
            compileError = validation.message
            return
        }
        Task { @MainActor in
            do {
                try await transport.install(payload: data, on: device)
            } catch let error as TransportError {
                compileError = error.errorDescription
            } catch {
                compileError = error.localizedDescription
            }
        }
    }

    private func writeTemporary(_ data: Data, ext: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
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

    private var compiledFileName: String {
        let base = exportName.isEmpty ? editor.project.name : exportName
        let safe = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).bin"
    }
}