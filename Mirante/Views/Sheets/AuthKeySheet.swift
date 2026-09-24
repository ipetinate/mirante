import SwiftUI

/// Lets the user paste the 32-hex band auth key pulled from an Android Mi
/// Fitness install. Without it Mirante stays in create/share mode; with it the
/// install flow knows the handshake secret it needs.
struct AuthKeySheet: View {
    @Environment(BandTransport.self) private var transport
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""

    private var isValid: Bool {
        AuthKeyStore.isValid(input)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Auth key (32 hex)", text: $input)
                        .font(.system(.body, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.none)
                        #endif
                } header: {
                    Text("Band Auth Key")
                } footer: {
                    Text("The 32-character key is pulled from the Mi Fitness app data on an Android phone (root required on newer versions). It authenticates Mirante to the band before any file transfer. Mirante never sends it anywhere else and stores it only in the Keychain.")
                }

                Section {
                    LabeledContent("Status") {
                        if isValid {
                            Label("Valid", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if input.isEmpty {
                            Text("Empty")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(input.count)/32 hex")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let current = transport.authKey {
                    Section {
                        LabeledContent("Stored") {
                            Text(mask(current))
                                .font(.system(.body, design: .monospaced))
                        }
                        Button("Remove Key", role: .destructive) {
                            transport.setAuthKey(nil)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
            .navigationTitle("Auth Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if setKey() != nil { dismiss() }
                    }
                    .disabled(!isValid)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 420, minHeight: 400)
        #endif
    }

    @discardableResult
    private func setKey() -> String? {
        guard isValid else { return nil }
        let key = AuthKeyStore.normalized(input)
        input = key
        return transport.setAuthKey(key)
    }

    private func mask(_ key: String) -> String {
        String(key.prefix(4)) + "…" + String(key.suffix(4))
    }
}