import SwiftUI

/// The Explore screen: a full-screen (non-sheet) browser for the watchfaces
/// made in the app — autosaved projects and imported files alike. Shows a
/// featured presentation of the newest face, live search, and a newest-first
/// grid, plus the placeholder for the upcoming GitHub-backed store.
struct ExploreView: View {
    @Environment(EditorState.self) private var editor

    @State private var searchText = ""
    @State private var selectedRecent: RecentProject?
    @State private var selectedCompiled: CompiledFace?
    @State private var selectedStoreFace: StoreFace?
    @State private var storeManifest: StoreManifest?
    @State private var storeError: String?
    @State private var showStoreConfig = false

    /// Newest first: the recents list is kept that way by RecentsStore.
    private var faces: [RecentProject] { editor.recents }

    private var storeFaces: [StoreFace] {
        storeManifest?.faces ?? []
    }

    private var filteredStoreFaces: [StoreFace] {
        guard !searchText.isEmpty else { return storeFaces }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return storeFaces.filter {
            $0.name.lowercased().contains(query) || ($0.device?.name.lowercased().contains(query) ?? false)
        }
    }

    /// Matches on face name and device name so a search like "redmi" works.
    private var filteredFaces: [RecentProject] {
        guard !searchText.isEmpty else { return faces }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return faces.filter {
            $0.name.lowercased().contains(query) || $0.device.name.lowercased().contains(query)
        }
    }

    private var featured: RecentProject? { faces.first }

    var body: some View {
        NavigationStack {
            Group {
                if faces.isEmpty && editor.compiledFaces.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Explore Yet",
                        systemImage: "square.grid.2x2",
                        description: Text("Create your first watchface from the home screen, or import a compiled .bin / .face to install on your band.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if searchText.isEmpty, let featured {
                                presentation(featured)
                            }
                            if !filteredFaces.isEmpty {
                                grid(filteredFaces)
                            } else if !faces.isEmpty {
                                ContentUnavailableView.search(text: searchText)
                                    .frame(maxWidth: .infinity)
                            }
                            compiledSection
                            storeSection
                        }
                        .padding(20)
                        .frame(maxWidth: 720, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Explore")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .searchable(text: $searchText, prompt: "Search by name or device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        editor.isExploring = false
                    } label: {
                        Label("Home", systemImage: "chevron.backward")
                    }
                    .help("Back to home")
                }
            }
            .navigationDestination(item: $selectedRecent) { recent in
                FaceDetailView(recent: recent)
            }
            .navigationDestination(item: $selectedCompiled) { face in
                CompiledFaceDetailView(face: face)
            }
            .navigationDestination(item: $selectedStoreFace) { face in
                StoreFaceDetailView(face: face)
            }
            .onAppear {
                editor.refreshRecents()
                loadStore()
            }
            .sheet(isPresented: $showStoreConfig) {
                StoreConfigSheet()
            }
        }
    }

    // MARK: - Presentation (featured watchface)

    /// Showcase of the newest face: live preview plus metadata, tappable to
    /// open it.
    private func presentation(_ recent: RecentProject) -> some View {
        Button {
            selectedRecent = recent
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Text("Featured")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                HStack(spacing: 18) {
                    LivePreviewView(
                        widgets: RecentsStore.content(of: recent)?.widgets ?? [],
                        screen: recent.device.screenSize,
                        device: recent.device,
                        images: RecentsStore.content(of: recent)?.images ?? [:]
                    )
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(recent.name)
                            .font(.title3.bold())
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        Text(recent.device.name)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if recent.isImported == true {
                                badge("Imported", color: .blue)
                            }
                            Text("Updated \(recent.updatedAt.formatted())")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.quaternary.opacity(0.3))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Grid

    private func grid(_ items: [RecentProject]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)
            ],
            spacing: 14
        ) {
            ForEach(items) { recent in
                faceCell(recent)
            }
        }
    }

    private func faceCell(_ recent: RecentProject) -> some View {
        Button {
            selectedRecent = recent
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                LivePreviewView(
                    widgets: RecentsStore.content(of: recent)?.widgets ?? [],
                    screen: recent.device.screenSize,
                    device: recent.device,
                    images: RecentsStore.content(of: recent)?.images ?? [:]
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if recent.isImported == true {
                            badge("Imported", color: .blue)
                        }
                        Text(recent.device.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Compiled faces

    /// Imported .bin / .face binaries, ready to install on a band.
    private var compiledSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compiled Faces")
                .font(.headline)
            if editor.compiledFaces.isEmpty {
                HStack(spacing: 10) {
                    Text("Compiled binaries (.bin / .face) from the Mi companion app or the Windows toolchain can be installed directly on your band. Import one to install it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Import…") { editor.showCompiledFaceImporter = true }
                        .buttonStyle(.bordered)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(editor.compiledFaces) { face in
                        compiledRow(face)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compiledRow(_ face: CompiledFace) -> some View {
        Button {
            selectedCompiled = face
        } label: {
            HStack(spacing: 12) {
                Image(systemName: face.isFaceFile ? "face.smiling" : "cube.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(face.name)
                        .lineLimit(1)
                    Text("\(face.fileExtension.uppercased()) · \(formattedSize(face.sizeBytes)) · \(face.addedAt.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.25))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                editor.removeCompiledFace(face)
            }
        }
    }

    private func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Store

    private var storeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Store")
                    .font(.headline)
                Spacer()
                if StoreConfigStore.isConfigured {
                    Button {
                        loadStore()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Configure Store…") { showStoreConfig = true }
                        .buttonStyle(.bordered)
                }
            }

            if !StoreConfigStore.isConfigured {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A curated store of watchfaces hosted on GitHub — publish your own or install faces others have prepared.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Point the store at your GitHub repository to browse and publish.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.quaternary.opacity(0.25))
                }
            } else if let storeError {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Store unavailable", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.medium))
                    Text(storeError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.quaternary.opacity(0.25))
                }
            } else if storeManifest == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading store…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if filteredStoreFaces.isEmpty {
                Text("No faces published yet. Publish your own from the editor to seed the store.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary.opacity(0.25))
                    }
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)
                    ],
                    spacing: 14
                ) {
                    ForEach(filteredStoreFaces) { face in
                        storeFaceCell(face)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func storeFaceCell(_ face: StoreFace) -> some View {
        Button {
            selectedStoreFace = face
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RemotePreview(face: face)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .background(.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(face.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !face.compiled {
                            Text("Compiling")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.15), in: Capsule())
                        }
                        Text(face.device?.name ?? face.deviceID)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadStore() {
        storeError = nil
        storeManifest = nil
        let config = StoreConfigStore.config
        guard config.isConfigured else { return }
        Task { @MainActor in
            do {
                storeManifest = try await StoreClient().fetchManifest(config)
            } catch {
                storeError = error.localizedDescription
            }
        }
    }
}

/// Detail screen for a single watchface, presented as a store item: large
/// live preview, metadata, a publisher-details menu, and actions to publish to
/// the store or open the editor. Opening a face here never silently jumps into
/// the editor — editing is an explicit choice.
struct FaceDetailView: View {
    @Environment(EditorState.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let recent: RecentProject

    @State private var showPublishSheet = false
    @State private var showConfigSheet = false

    private var project: WatchFaceProject? {
        RecentsStore.content(of: recent)
    }

    private var storeConfig: StoreConfig { StoreConfigStore.config }

    var body: some View {
        Group {
            if let project {
                VStack(spacing: 16) {
                    LivePreviewView(
                        widgets: project.widgets,
                        screen: project.screenSize,
                        device: project.device,
                        images: project.images
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(project.name)
                            .font(.title3.bold())
                        LabeledContent("Device") {
                            Text("\(project.device.name) · \(Int(project.screenSize.width)) × \(Int(project.screenSize.height))")
                        }
                        LabeledContent("Widgets") {
                            Text("\(project.widgets.count)")
                        }
                        if !project.aodWidgets.isEmpty {
                            LabeledContent("Always-On Display") {
                                Text("\(project.aodWidgets.count) widget(s)")
                            }
                        }
                        LabeledContent("Updated") {
                            Text(recent.updatedAt.formatted())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)

                    VStack(spacing: 10) {
                        Button {
                            if storeConfig.isConfigured {
                                showPublishSheet = true
                            } else {
                                showConfigSheet = true
                            }
                        } label: {
                            Label(
                                storeConfig.isConfigured ? "Publish to Store" : "Set Up Store…",
                                systemImage: "arrow.up.circle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            editor.loadProject(project)
                            editor.isExploring = false
                        } label: {
                            Label("Edit in Editor", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            } else {
                ContentUnavailableView(
                    "Unreadable Watchface",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This project's data could not be read.")
                )
            }
        }
        .navigationTitle(recent.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                publisherMenu
            }
        }
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet()
        }
        .sheet(isPresented: $showConfigSheet) {
            StoreConfigSheet()
        }
    }

    /// The publisher-details menu: who owns the store entry (the configured
    /// publisher), where it lives, and direct access to publish / configure.
    private var publisherMenu: some View {
        Menu {
            if storeConfig.isConfigured {
                Section {
                    Label(
                        storeConfig.publisherName.isEmpty
                            ? storeConfig.publisherHandle
                            : storeConfig.publisherName,
                        systemImage: "person.crop.circle"
                    )
                    Text("@\(storeConfig.publisherHandle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Publish to Store") { showPublishSheet = true }
                if let repoURL = repoURL {
                    Button("Open Store Repository") { openURL(repoURL) }
                }
            } else {
                Section {
                    Text("Not published yet")
                }
                Button("Set Up Store…") { showConfigSheet = true }
            }
            Divider()
            Button("Store Settings…") { showConfigSheet = true }
        } label: {
            Label("Publisher", systemImage: "person.crop.circle.badge")
        }
        .help("Publisher details")
    }

    private var repoURL: URL? {
        guard !storeConfig.owner.isEmpty, !storeConfig.repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(storeConfig.owner)/\(storeConfig.repository)")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Detail screen for a compiled .bin / .face: metadata plus the hand-off that
/// installs it on a paired band. Compiled faces cannot be edited or previewed.
struct CompiledFaceDetailView: View {
    @Environment(EditorState.self) private var editor
    @Environment(BandTransport.self) private var transport

    let face: CompiledFace

    @State private var installError: String?
    @State private var showAuthKeySheet = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.black)
                VStack(spacing: 10) {
                    Image(systemName: face.isFaceFile ? "face.smiling" : "cube.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(face.fileExtension.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 220)

            VStack(alignment: .leading, spacing: 8) {
                Text(face.name)
                    .font(.title3.bold())
                LabeledContent("Type", value: face.isFaceFile ? "Compiled face (.face)" : "Compiled binary (.bin)")
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(face.sizeBytes), countStyle: .file))
                LabeledContent("Added", value: face.addedAt.formatted())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: send) {
                Label(
                    transport.isConnected ? "Install to Band" : "Connect & Install",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("A compiled face is installed as-is. It cannot be edited here, and Mirante validates the file format and size before sending. Installation honors the file exactly — make sure it was made for this band.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 460)
        .navigationTitle(face.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

    private func send() {
        guard transport.isConnected else {
            editor.pendingInstallFace = face
            editor.showConnectionSheet = true
            return
        }
        if transport.authKey == nil {
            showAuthKeySheet = true
            return
        }
        Task { await installNow() }
    }

    @MainActor
    private func installNow() async {
        guard let band = transport.connectedDevice else {
            installError = TransportError.deviceNotPaired.errorDescription
            return
        }
        guard let data = try? Data(contentsOf: face.fileURL) else {
            installError = String(localized: "The face file could not be read.")
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
}

/// Loads a face's cover image from the store repository.
struct RemotePreview: View {
    let face: StoreFace
    @State private var image: Image?
    @State private var failed = false

    private var config: StoreConfig { StoreConfigStore.config }

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(8)
            } else if failed {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ProgressView()
                    .tint(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: face.id) {
            guard previewPathNeedsLoading, let previewPath = face.previewPath else { return }
            do {
                let data = try await StoreClient().download(path: previewPath, config: config)
                image = StoreFaceDetailView.decodeImage(data)
                failed = image == nil
            } catch {
                failed = true
            }
        }
    }

    private var previewPathNeedsLoading: Bool {
        image == nil && !failed
    }
}
