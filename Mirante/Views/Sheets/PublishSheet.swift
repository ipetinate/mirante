import SwiftUI

/// Publishes the current editable project to the GitHub store: writes the
/// source `.fprj`, `metadata.json`, a rendered `preview.png` and the compiled
/// `face.bin` (built in-app) under `faces/<publisher>/<slug>/`, plus an
/// `index.json` update. The face shows up in Explore immediately as compiled.
struct PublishSheet: View {
    @Environment(EditorState.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var version = "1.0.0"
    @State private var description = ""
    @State private var tags = ""
    @State private var isPublishing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Face") {
                    TextField("Name", text: $name)
                    TextField("Version", text: $version)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Tags, comma-separated", text: $tags)
                }

                Section("Store target") {
                    let config = StoreConfigStore.config
                    LabeledContent("Repository") {
                        Text("\(config.owner)/\(config.repository)")
                    }
                    LabeledContent("Publisher") {
                        Text(config.publisherName.isEmpty ? config.publisherHandle : config.publisherName)
                    }
                }

                Section {
                    Button {
                        Task { await publish() }
                    } label: {
                        if isPublishing {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Publishing…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("Publish to Store")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isPublishing)
                }

                Section {
                    Text("Publishing stores the editable project, a rendered preview and the compiled .bin (built in-app) — the face is immediately installable from the store. Each version overwrites the previous one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Publish to Store")
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .onAppear { if name.isEmpty { name = editor.project.name } }
            .alert("Publish Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    @MainActor
    private func publish() async {
        guard let token = StoreConfigStore.token, !token.isEmpty else {
            errorMessage = StoreError.missingToken.errorDescription
            return
        }
        isPublishing = true
        defer { isPublishing = false }

        var project = editor.project
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.touch()

        let config = StoreConfigStore.config
        let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let binData: Data
        do {
            binData = try FaceBinCompiler.compile(project)
        } catch {
            errorMessage = String(localized: "Could not compile the .bin for this face.")
            return
        }
        let face = StoreFace.make(from: project, config: config, version: version.isEmpty ? "1.0.0" : version, description: description, tags: tagList, binData: binData)

        let metadata: Data
        do {
            metadata = try StoreJSON.encoder.encode(face)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard let previewData = PreviewRenderer.renderPNG(project, editor: editor) else {
            errorMessage = String(localized: "Could not render the face preview.")
            return
        }

        let client = StoreClient()
        do {
            try await client.publish(
                face: face,
                fprjData: project.exportData(),
                metadataData: metadata,
                previewData: previewData,
                binData: binData,
                config: config,
                token: token
            )
            // Keep a local copy so the face stays editable after publishing.
            editor.persistCurrentProject()
            dismiss()
            editor.isExploring = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}