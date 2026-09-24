import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A published store face shown as a store item: cover art, metadata, the
/// publisher's details behind a menu, and an install action that mirrors the
/// compiled-face flow (download the .bin, then hand it to the band transport).
struct StoreFaceDetailView: View {
    @Environment(EditorState.self) private var editor
    @Environment(BandTransport.self) private var transport
    @Environment(\.openURL) private var openURL

    let face: StoreFace

    @State private var coverImage: Image?
    @State private var coverData: Data?
    @State private var coverFailed = false
    @State private var isDownloading = false
    @State private var installError: String?
    @State private var showAuthKeySheet = false

    private var config: StoreConfig { StoreConfigStore.config }

    var body: some View {
        VStack(spacing: 16) {
            cover

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(face.name)
                        .font(.title3.bold())
                    if !face.compiled {
                        compilerBadge
                    }
                }
                LabeledContent("Author") {
                    Text(face.author.name.isEmpty ? face.author.handle : face.author.name)
                }
                LabeledContent("Device") {
                    Text(face.device?.name ?? face.deviceID)
                }
                LabeledContent("Version") {
                    Text(face.version)
                }
                LabeledContent("Updated") {
                    Text(face.updatedAt.formatted())
                }
                if let binarySize = face.binarySize {
                    LabeledContent("Size") {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(binarySize), countStyle: .file))
                    }
                }
                if !face.description.isEmpty {
                    Text(face.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !face.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(face.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.tertiary.opacity(0.4), in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: send) {
                Label(
                    installLabel,
                    systemImage: face.compiled ? "antenna.radiowaves.left.and.right" : "hourglass"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!face.compiled || isDownloading)
            #if os(macOS)
            .keyboardShortcut(.return, modifiers: [])
            #endif

            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 460)
        .navigationTitle(face.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section {
                        Label(face.author.name.isEmpty ? face.author.handle : face.author.name, systemImage: "person.crop.circle")
                        Text("@\(face.author.handle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let profileURL = profileURL {
                        Button("Open Publisher Profile") {
                            openURL(profileURL)
                        }
                    }
                    if let storeURL = storeURL {
                        Button("Open Store Repository") {
                            openURL(storeURL)
                        }
                    }
                } label: {
                    Label("Publisher", systemImage: "person.crop.circle.badge.checkmark")
                }
                .help("Publisher details")
            }
        }
        .onAppear { Task { await loadCoverIfNeeded() } }
        .alert("Install Failed", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "")
        }
        .sheet(isPresented: $showAuthKeySheet) {
            AuthKeySheet()
        }
    }

    private var compilerBadge: some View {
        Text("Compiling")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.15), in: Capsule())
    }

    private var installLabel: String {
        if !face.compiled {
            return "Awaits Store CI"
        }
        if isDownloading {
            return "Downloading…"
        }
        return transport.isConnected ? "Install to Band" : "Connect & Install"
    }

    private var footnote: String {
        if !face.compiled {
            return "Faces published before in-app compilation existed aren't compiled yet on the store."
        }
        return "Installs the store's compiled binary as-is. Mirante validates the file format and size before sending."
    }

    // MARK: - Cover

    @ViewBuilder
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black)
            if let coverImage {
                coverImage
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(10)
            } else if coverFailed {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Cover unavailable")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                ProgressView()
                    .tint(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 240)
    }

    private func loadCoverIfNeeded() async {
        guard coverData == nil, !coverFailed, let previewPath = face.previewPath else { return }
        do {
            let data = try await StoreClient().download(path: previewPath, config: config)
            let image = StoreFaceDetailView.decodeImage(data)
            coverData = data
            coverImage = image ?? Image(systemName: "applewatch.watchface")
            coverFailed = image == nil
        } catch {
            coverFailed = true
        }
    }

    static func decodeImage(_ data: Data) -> Image? {
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #endif
    }

    // MARK: - Links

    private var profileURL: URL? {
        guard !face.author.handle.isEmpty else { return nil }
        return URL(string: "https://github.com/\(face.author.handle)")
    }

    private var storeURL: URL? {
        URL(string: "https://github.com/\(config.owner)/\(config.repository)")
    }

    // MARK: - Install

    private func send() {
        guard face.compiled, let binaryPath = face.binaryPath else { return }
        isDownloading = true
        Task { @MainActor in
            defer { isDownloading = false }
            do {
                let data = try await StoreClient().download(path: binaryPath, config: config)
                await install(data: data)
            } catch {
                installError = error.localizedDescription
            }
        }
    }

    private func install(data: Data) async {
        guard transport.isConnected else {
            // Hand off to the connection sheet: park the binary as a compiled
            // face so the existing connect-then-install flow drives it.
            let binary = saveBinaryLocally(data)
            if let binary {
                editor.pendingInstallFace = binary
                editor.showConnectionSheet = true
            } else {
                installError = String(localized: "Could not store the downloaded binary.")
            }
            return
        }
        guard transport.authKey != nil else {
            showAuthKeySheet = true
            return
        }
        guard let band = transport.connectedDevice else {
            installError = TransportError.deviceNotPaired.errorDescription
            return
        }
        let device = band.deviceID.flatMap(Device.find) ?? Device.all[0]
        let validation = transport.validate(payload: data, for: device)
        guard validation.isOk else {
            installError = validation.message
            return
        }
        do {
            try await transport.install(payload: data, on: device)
        } catch let error as TransportError {
            switch error {
            case .authKeyMalformed:
                installError = error.errorDescription
            case .authKeyRequired:
                showAuthKeySheet = true
            default:
                installError = error.errorDescription
            }
        } catch {
            installError = error.localizedDescription
        }
    }

    private func saveBinaryLocally(_ data: Data) -> CompiledFace? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        do {
            try data.write(to: temp)
        } catch {
            return nil
        }
        return CompiledFacesStore.add(copying: temp, name: face.name)
    }
}