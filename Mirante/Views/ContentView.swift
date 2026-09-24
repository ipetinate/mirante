import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(EditorState.self) private var editor
    @Environment(BandTransport.self) private var bandTransport
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showImagePicker = false

    var body: some View {
        @Bindable var editor = editor

        Group {
            if editor.isExploring {
                ExploreView()
            } else if editor.homeVisible {
                HomeView()
            } else {
                #if os(iOS)
                NavigationStack {
                    EditorCanvasView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            WidgetLayerCarousel()
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                HomeButton()
                            }
                            EditorToolbar()
                            ToolbarItem(placement: .topBarTrailing) {
                                DeviceButton()
                            }
                        }
                }
                #else
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    LayersSidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } content: {
                    EditorCanvasView()
                } detail: {
                    InspectorView()
                        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                }
                #endif
            }
        }
        #if os(macOS)
        .forcedWindowFrame()
        .toolbar {
            if !editor.homeVisible && !editor.isExploring {
                EditorToolbar()
                ToolbarItem(placement: .navigation) {
                    HomeButton()
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        #else
        .navigationTitle(editor.homeVisible ? "Mirante" : (editor.isExploring ? "Explore" : editor.project.name))
        #endif
        .sheet(isPresented: $editor.showNewProjectSheet) {
            NewProjectSheet()
        }
        .sheet(isPresented: $editor.showConnectionSheet) {
            ConnectionSheet()
        }
        .sheet(isPresented: $editor.showWidgetEditor) {
            WidgetEditorSheet()
        }
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard let kind = editor.imageImportRequest?.kind else { return }
            defer { editor.imageImportRequest = nil }
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            editor.importImage(at: url, kind: kind)
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        .fileImporter(
            isPresented: $editor.showFprjImporter,
            allowedContentTypes: [fprjType],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            editor.importProject(at: url)
        }
        .fileImporter(
            isPresented: $editor.showCompiledFaceImporter,
            allowedContentTypes: compiledFaceTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            editor.importCompiledFace(at: url)
        }
        .onChange(of: editor.imageImportRequest?.kind) { _, kind in
            guard kind != nil else { return }
            showImagePicker = true
        }
        .onChange(of: editor.project) { _, _ in
            editor.scheduleAutosave()
        }
        .onAppear {
            editor.refreshRecents()
            editor.refreshCompiledFaces()
        }
    }

    /// The dynamic UTI for ".fprj" files, produced/read by Mirante.
    private var fprjType: UTType {
        UTType(filenameExtension: "fprj") ?? .data
    }

    /// UTI for the compiled watchface binaries Mirante can receive.
    private var compiledFaceTypes: [UTType] {
        [UTType(filenameExtension: "bin") ?? .data, UTType(filenameExtension: "face") ?? .data]
    }
}

/// Toolbar shortcut back to the home screen, with a live "connected" dot.
private struct HomeButton: View {
    @Environment(EditorState.self) private var editor
    @Environment(BandTransport.self) private var transport

    var body: some View {
        Button {
            editor.goHome()
        } label: {
            ConnectionDotLabel(title: "Home", systemImage: "house")
        }
        .help("Back to home")
    }
}

/// Toolbar button that opens the band connection screen, marked when connected.
struct DeviceButton: View {
    @Environment(EditorState.self) private var editor
    @Environment(BandTransport.self) private var transport

    var body: some View {
        Button {
            editor.showConnectionSheet = true
        } label: {
            ConnectionDotLabel(title: "Device", systemImage: "antenna.radiowaves.left.and.right")
        }
        .help(transport.isConnected ? "Connected — open device" : "Connect a band")
    }
}

/// A bordered "connected" dot shown on buttons that talk to a band.
private struct ConnectionDotLabel: View {
    @Environment(BandTransport.self) private var transport
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .overlay(alignment: .topTrailing) {
                if transport.isConnected {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: -8)
                }
            }
    }
}

// MARK: - Home screen

/// First screen of the app: create, import, or reopen a recent project.
struct HomeView: View {
    @Environment(EditorState.self) private var editor
    @Environment(BandTransport.self) private var transport

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Mirante")
                        .font(.largeTitle.bold())
                    Text("Make your own watch face. Create one from scratch, import an existing project, or pick up where you left off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 430)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    choiceCard(title: "New Project", icon: "plus.circle.fill") {
                        editor.showNewProjectSheet = true
                    }
                    importProjectMenu
                    connectDeviceCard
                    choiceCard(title: "Explore", icon: "square.grid.2x2") {
                        editor.openExplore()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent Projects")
                        .font(.headline)
                    if editor.recents.isEmpty {
                        Text("No recent projects yet. New projects are saved automatically in the app folder so you can continue them here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(editor.recents) { recent in
                            recentRow(recent)
                        }
                    }
                }
                .frame(maxWidth: 430)
            }
            .padding(24)
        }
        .frame(maxWidth: 560)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Imports either an editable Mi Create/Mirante project (.fprj) or a
    /// compiled watchface binary (.bin / .face) that is only viewable and
    /// installable.
    private var importProjectMenu: some View {
        Menu {
            Button {
                editor.showFprjImporter = true
            } label: {
                Label("Mi Create/Mirante project (.fprj)", systemImage: "doc")
            }
            Button {
                editor.showCompiledFaceImporter = true
            } label: {
                Label("Compiled Face (.bin / .face)", systemImage: "cube")
            }
        } label: {
            cardLabel(title: "Import Project", icon: "folder")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    private var connectDeviceCard: some View {
        ZStack(alignment: .topTrailing) {
            choiceCard(title: transport.isConnected ? "Device Connected" : "Connect Device",
                       icon: "antenna.radiowaves.left.and.right") {
                editor.showConnectionSheet = true
            }
            if transport.isConnected {
                Circle()
                    .fill(.green)
                    .frame(width: 12, height: 12)
                    .padding(10)
            }
        }
    }

    private func choiceCard(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            cardLabel(title: title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func cardLabel(title: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private func recentRow(_ recent: RecentProject) -> some View {
        Button {
            editor.openRecent(recent)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.name)
                        .lineLimit(1)
                    Text("\(recent.device.name) · \(recent.updatedAt.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.25))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - iOS/iPadOS widgets carousel + editor sheet

/// A compact horizontal strip of widget layers shown over the focused preview
/// on iOS/iPadOS. Tapping a card opens the editing bottom sheet.
struct WidgetLayerCarousel: View {
    @Environment(EditorState.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var dropRow: Int?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                addCard
                ForEach(Array(displayWidgets.enumerated()), id: \.element.id) { displayRow, widget in
                    LayerCard(
                        widget: widget,
                        isSelected: editor.selection == widget.id,
                        isDropTarget: dropRow == displayRow
                    )
                        .onTapGesture {
                            editor.selection = widget.id
                            editor.showWidgetEditor = true
                        }
                        .draggable(widget.id.uuidString) {
                            LayerCardDragPreview(widget: widget)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                            editor.moveWidget(id, toDisplayRow: displayRow)
                            return true
                        } isTargeted: { isTargeted in
                            dropRow = isTargeted ? displayRow : dropRow
                        }
                        .contextMenu {
                            Button("Duplicate") {
                                editor.selection = widget.id
                                editor.duplicateSelected()
                            }
                            Button("Rename…") {
                                editor.selection = widget.id
                                editor.showWidgetEditor = true
                            }
                            Button("Delete", role: .destructive) {
                                editor.selection = widget.id
                                editor.deleteSelected()
                            }
                        }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .background(.thinMaterial)
        .frame(height: 92)
    }

    private var displayWidgets: [WidgetItem] {
        Array(editor.activeWidgets).reversed()
    }

    private var addCard: some View {
        Menu {
            ForEach(WidgetKind.allCases.filter { $0.isAddable(for: editor.project.format) }) { kind in
                Button {
                    if kind == .image || kind == .imageList {
                        editor.requestImageImport(kind: kind)
                    } else {
                        editor.addWidget(kind: kind)
                    }
                } label: {
                    Label(kind.displayName, systemImage: kind.systemImage)
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Add")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 76, height: 76)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
    }
}

private struct LayerCard: View {
    let widget: WidgetItem
    let isSelected: Bool
    var isDropTarget = false

    var body: some View {
        VStack(spacing: 4) {
            WidgetThumb(widget: widget)
            Text(widget.name)
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(width: 76)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(isDropTarget ? 0.75 : (isSelected ? 0.55 : 0.3)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : (isDropTarget ? Color.accentColor.opacity(0.6) : .clear), lineWidth: 1.5)
        }
        .contentShape(Rectangle())
    }
}

/// Floating preview shown while dragging a layer card to reorder it.
private struct LayerCardDragPreview: View {
    let widget: WidgetItem

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: widget.kind.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(widget.name)
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(width: 76)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
    }
}

/// A small black device box overlaying a live preview of a single widget.
private struct WidgetThumb: View {
    @Environment(EditorState.self) private var editor
    let widget: WidgetItem

    private let thumbSize: CGFloat = 56

    var body: some View {
        GeometryReader { proxy in
            let w = max(CGFloat(widget.width), 1)
            let h = max(CGFloat(widget.height), 1)
            let scale = min(proxy.size.width / w, proxy.size.height / h)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black)
                WidgetPreviewView(widget: widget, scale: scale, deviceID: editor.project.deviceID, images: editor.project.images)
                    .frame(width: w * scale, height: h * scale)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(width: thumbSize, height: thumbSize)
    }
}

/// Half-screen editor sheet on iOS/iPadOS: the details form on the bottom,
/// while the top half keeps showing the live canvas.
struct WidgetEditorSheet: View {
    @Environment(EditorState.self) private var editor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var editor = editor

        NavigationStack {
            Group {
                if let widget = editor.selectedWidget {
                    InspectorForm(widget: widget)
                } else {
                    ContentUnavailableView(
                        "Nothing Selected",
                        systemImage: "slider.horizontal.3",
                        description: Text("Select a widget to edit its properties.")
                    )
                }
            }
            .navigationTitle(editor.selectedWidget?.name ?? "Widget")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    ContentView()
        .environment(EditorState())
        .environment(BandTransport())
}