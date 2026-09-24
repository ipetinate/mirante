import SwiftUI

/// Collects the GitHub store configuration: where the store repo lives and
/// under which publisher handle faces are published. The token is written one
/// keystroke at a time straight to the Keychain; the rest is saved on demand.
// MARK: - Cross-platform modifier

private extension View {
    @ViewBuilder
    func storeFieldAutocapitalizationDisabled() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}

struct StoreConfigSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var owner: String
    @State private var repository: String
    @State private var branch: String
    @State private var publisherHandle: String
    @State private var publisherName: String
    @State private var token: String

    init() {
        let config = StoreConfigStore.config
        _owner = State(initialValue: config.owner)
        _repository = State(initialValue: config.repository)
        _branch = State(initialValue: config.branch)
        _publisherHandle = State(initialValue: config.publisherHandle)
        _publisherName = State(initialValue: config.publisherName)
        _token = State(initialValue: StoreConfigStore.token ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository") {
                    TextField("Owner", text: $owner)
                        .storeFieldAutocapitalizationDisabled()
                    TextField("Repository", text: $repository)
                        .storeFieldAutocapitalizationDisabled()
                    TextField("Branch", text: $branch)
                        .storeFieldAutocapitalizationDisabled()
                }

                Section("Publisher") {
                    TextField("GitHub handle", text: $publisherHandle)
                        .storeFieldAutocapitalizationDisabled()
                    TextField("Display name", text: $publisherName)
                }

                Section("Access token") {
                    SecureField("GitHub token", text: $token)
                        .storeFieldAutocapitalizationDisabled()
                    Text("Only needed to publish. Browsing the store reads public files. Create a token in GitHub → Settings → Developer settings → Personal access tokens with the \u{201C}repo\u{201D} scope.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Save", action: save)
                        .disabled(!storeConfig.isConfigured)
                }

                if !StoreConfigStore.config.isConfigured {
                    Section {
                        Text("The store is an ordinary GitHub repository. Create it (e.g. platform.github.com/new → \u{201C}MiranteStore\u{201D}) and the repo is writable by the token above.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Store Settings")
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .onChange(of: token) { _, newValue in
                if newValue.isEmpty {
                    StoreConfigStore.clearToken()
                } else {
                    StoreConfigStore.setToken(newValue)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private var storeConfig: StoreConfig {
        StoreConfig(
            owner: owner.trimmingCharacters(in: .whitespacesAndNewlines),
            repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
            branch: branch.isEmpty ? StoreConfig.defaultBranch : branch,
            publisherHandle: publisherHandle.trimmingCharacters(in: .whitespacesAndNewlines),
            publisherName: publisherName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func save() {
        StoreConfigStore.config = storeConfig
        dismiss()
    }
}