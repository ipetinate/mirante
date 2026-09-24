import ImageIO
import Observation
import SwiftUI

@MainActor
@Observable
final class EditorState {
    var project: WatchFaceProject
    var selection: UUID?
    var isAODActive = false
    var zoom: CGFloat = 1
    var showGrid = false
    var clipboard: WidgetItem?
    var showNewProjectSheet = false
    /// True while the band connection / install sheet should be presented.
    var showConnectionSheet = false
    /// True while the explore screen (your watchfaces + future store) is shown
    /// instead of the home/editor. It is a full screen, not a sheet.
    var isExploring = false
    /// When true the home screen (create / import / recents) is shown
    /// instead of the editor. This is the first screen on launch and is
    /// reachable anytime through the Home toolbar button.
    var homeVisible = true
    /// Non-empty while the widget editor bottom sheet should be presented (iOS).
    var showWidgetEditor = false
    /// Non-empty while the fprj import picker should be presented.
    var showFprjImporter = false
    /// Non-empty while the compiled face (.bin / .face) picker is presented.
    var showCompiledFaceImporter = false
    /// The last autosaved projects, shown on the home screen.
    var recents: [RecentProject] = []
    /// Compiled watchfaces (.bin / .face) imported to view and install.
    var compiledFaces: [CompiledFace] = []
    /// Set when the user picks a compiled face to install; the install flow
    /// uses it once a band is connected.
    var pendingInstallFace: CompiledFace?
    /// Non-empty while the image picker should be presented (set by toolbar Add).
    var imageImportRequest: ImageImportRequest?
    /// In-memory image data per widget id, only to render real previews.
    var runtimeImages: [UUID: Data] = [:]

    private let history = History()
    private var autosaveTask: Task<Void, Never>?

    /// Observable mirror of undo/redo availability so toolbar controls update.
    var undoLevels = 0
    var redoLevels = 0

    init(project: WatchFaceProject = .new(name: "Untitled", device: Device.all[0])) {
        self.project = project
    }

    // MARK: - Widgets

    var activeWidgets: [WidgetItem] {
        get { isAODActive ? project.aodWidgets : project.widgets }
        set {
            if isAODActive { project.aodWidgets = newValue } else { project.widgets = newValue }
            project.touch()
        }
    }

    func replaceActiveWidgets(_ widgets: [WidgetItem]) {
        activeWidgets = widgets
    }

    var selectedWidget: WidgetItem? {
        guard let selection else { return nil }
        return activeWidgets.first { $0.id == selection }
    }

    // MARK: - Commands

    private func execute(_ command: EditorCommand) {
        history.execute(command, state: self)
        refreshHistory()
    }

    private func recordModify(label: String, before: WidgetItem, after: WidgetItem) {
        history.recordModify(label: label, before: before, after: after, state: self)
        refreshHistory()
    }

    func addWidget(kind: WidgetKind) {
        let device = project.device
        var widget = WidgetItem(kind: kind, name: kind.displayName)
        widget.width = min(120, device.width / 3)
        widget.height = min(120, device.height / 4)
        widget.x = (device.width - widget.width) / 2
        widget.y = (device.height - widget.height) / 2
        switch kind {
        case .digitalNumber:
            widget.height = min(64, widget.height)
            widget.valueSourceID = "8"
            widget.digits = 2
        case .analog:
            widget.width = min(200, device.width * 2 / 3)
            widget.height = widget.width
            widget.x = (device.width - widget.width) / 2
            widget.y = (device.height - widget.height) / 2
        case .arc:
            widget.width = min(200, device.width * 2 / 3)
            widget.height = widget.width
            widget.x = (device.width - widget.width) / 2
            widget.y = (device.height - widget.height) / 2
            widget.valueSourceID = "23"
        case .imageList:
            widget.indexSourceID = "10"
        case .polyline:
            widget.width = min(300, device.width - 20)
            widget.height = min(80, device.height / 5)
            widget.x = max(0, (device.width - widget.width) / 2)
            widget.y = max(0, (device.height - widget.height) / 2)
            widget.polylineFilled = true
            widget.valueSourceID = "20"
            widget.rangeMin = 0
            widget.rangeMax = 100
        default:
            break
        }
        uniquifyName(&widget)
        let index = activeWidgets.count
        execute(AddWidgetCommand(widget: widget, index: index))
    }

    func deleteSelected() {
        guard let widget = selectedWidget,
              let index = activeWidgets.firstIndex(where: { $0.id == widget.id }) else { return }
        execute(DeleteWidgetCommand(widget: widget, index: index))
    }

    /// Fills the selected widget to the whole screen (which also centers it).
    func fitWidgetToScreen() {
        guard selection != nil else { return }
        let screen = project.screenSize
        update({ w in
            w.x = 0
            w.y = 0
            w.width = Int(screen.width.rounded())
            w.height = Int(screen.height.rounded())
        }, label: "Fit to Screen")
    }

    func copySelected() {
        clipboard = selectedWidget
    }

    func cutSelected() {
        copySelected()
        deleteSelected()
    }

    func renameWidget(_ id: UUID, to newName: String) {
        guard let idx = activeWidgets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var before = activeWidgets[idx]
        var after = before
        after.name = trimmed
        guard after.name != before.name else { return }
        recordModify(label: "Rename", before: before, after: after)
        if selection == nil { selection = id }
    }

    func paste() {
        guard var pasted = clipboard else { return }
        pasted.id = UUID()
        pasted.x += 16
        pasted.y += 16
        uniquifyName(&pasted)
        clipboard = pasted
        execute(AddWidgetCommand(widget: pasted, index: activeWidgets.count))
    }

    func duplicateSelected() {
        guard var copy = selectedWidget else { return }
        copy.id = UUID()
        copy.x += 16
        copy.y += 16
        uniquifyName(&copy)
        execute(AddWidgetCommand(widget: copy, index: activeWidgets.count))
    }

    func moveSelection(layerDirection: LayerDirection) {
        guard let id = selection else { return }
        let widgets = activeWidgets
        guard let idx = widgets.firstIndex(where: { $0.id == id }) else { return }
        let target: Int
        switch layerDirection {
        case .front: target = widgets.count - 1
        case .back: target = 0
        case .forward: target = min(widgets.count - 1, idx + 1)
        case .backward: target = max(0, idx - 1)
        }
        guard target != idx else { return }
        execute(ReorderWidgetCommand(widgetID: id, from: idx, to: target))
    }

    enum LayerDirection { case front, back, forward, backward }

    /// Asks for an image to be imported, then added as a widget.
    func requestImageImport(kind: WidgetKind) {
        imageImportRequest = ImageImportRequest(kind: kind)
    }

    /// Adds an image widget from a user-picked file, sized to the full screen
    /// width (aspect preserved) and centered. Returns the new widget id.
    @discardableResult
    func importImage(at url: URL, kind: WidgetKind) -> UUID? {
        guard let loaded = try? Data(contentsOf: url) else { return nil }
        // Bake any EXIF orientation into the pixels so the canvas, live preview
        // and export all render the image the way the camera saved it.
        let data = ImageTransform.normalized(loaded) ?? loaded

        let screen = project.screenSize
        var widget = WidgetItem(kind: kind, name: url.deletingPathExtension().lastPathComponent)
        if let size = imagePixelSize(data), size.width > 0, size.height > 0 {
            // Fit within the screen, preserving aspect: never overflow any edge.
            let s = min(
                CGFloat(Int(screen.width)) / size.width,
                CGFloat(Int(screen.height)) / size.height
            )
            widget.width = max(4, Int((size.width * s).rounded()))
            widget.height = max(4, Int((size.height * s).rounded()))
        } else {
            widget.width = min(120, Int(screen.width))
            widget.height = min(120, Int(screen.height))
        }
        widget.x = max(0, (Int(screen.width) - widget.width) / 2)
        widget.y = max(0, (Int(screen.height) - widget.height) / 2)
        widget.bitmap = url.lastPathComponent
        if kind == .imageList {
            widget.bitmapList = [url.lastPathComponent]
        }
        uniquifyName(&widget)
        execute(AddWidgetCommand(widget: widget, index: activeWidgets.count))
        setImage(data, for: widget.id)
        return widget.id
    }

    /// Records image data for a widget, both live (for the canvas/preview) and
    /// persisted inside the project so it survives relaunches.
    func setImage(_ data: Data, for widgetID: UUID) {
        runtimeImages[widgetID] = data
        project.images[widgetID.uuidString] = data
        scheduleAutosave()
    }

    /// Resolves rendered image data for a widget: the live override wins, then
    /// the persisted copy stored in the project.
    func imageData(for widgetID: UUID) -> Data? {
        runtimeImages[widgetID] ?? project.images[widgetID.uuidString]
    }

    private func imagePixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Live z-order matters: the LAST array element is drawn frontmost.
    /// Displaying the list reversed puts the frontmost widget on top.
    /// `displayRow` 0 (top of the list) => frontmost widget.
    func moveWidget(_ id: UUID, toDisplayRow displayRow: Int) {
        let widgets = activeWidgets
        guard let current = widgets.firstIndex(where: { $0.id == id }) else { return }
        let target = widgets.count - 1 - displayRow
        guard target != current, target >= 0, target < widgets.count else { return }
        execute(ReorderWidgetCommand(widgetID: id, from: current, to: target))
    }

    /// Repositions a widget (from a canvas drop) with its top-left at the
    /// given device-pixel point, without clamping: widgets may sit partially
    /// or fully outside the screen, hidden by the preview's overflow clip.
    func repositionWidget(_ id: UUID, toX x: Int, y: Int) {
        guard let idx = activeWidgets.firstIndex(where: { $0.id == id }) else { return }
        var before = activeWidgets[idx]
        var after = before
        after.x = x
        after.y = y
        guard before != after else { return }
        recordModify(label: "Move", before: before, after: after)
    }

    // MARK: - Polyline point editing (canvas)

    /// Moves a polyline point live while dragging it on the canvas. The point
    /// is in normalized space (0...1 within the widget).
    func updatePolylinePoint(_ id: UUID, index: Int, to point: CGPoint) {
        guard let idx = activeWidgets.firstIndex(where: { $0.id == id }) else { return }
        var before = activeWidgets[idx]
        guard before.kind == .polyline, before.pointList.indices.contains(index) else { return }
        var after = before
        after.pointList[index] = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        guard before != after else { return }
        recordModify(label: "Move Point", before: before, after: after)
    }

    /// Inserts a point into the polyline at the nearest spot on the drawn line
    /// to `point` (normalized 0...1, e.g. from a tap on the canvas).
    func insertPolylinePoint(_ id: UUID, at point: CGPoint) {
        guard let idx = activeWidgets.firstIndex(where: { $0.id == id }) else { return }
        var before = activeWidgets[idx]
        guard before.kind == .polyline, before.pointList.count >= 2 else { return }
        let target = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        var after = before
        let points = after.pointList
        var bestPair = -1
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var bestSpot = target
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t: CGFloat = 0
            if len2 > 0 {
                t = max(0, min(1, ((target.x - a.x) * dx + (target.y - a.y) * dy) / len2))
            }
            let spot = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = hypot(spot.x - target.x, spot.y - target.y)
            if distance < bestDistance {
                bestDistance = distance
                bestPair = i
                bestSpot = spot
            }
        }
        guard bestPair >= 0 else { return }
        after.pointList.insert(bestSpot, at: bestPair + 1)
        guard before != after else { return }
        recordModify(label: "Add Point", before: before, after: after)
    }

    // MARK: - Property editing

    func update(_ transform: (inout WidgetItem) -> Void, label: String = "Modify") {
        guard let id = selection,
              let idx = activeWidgets.firstIndex(where: { $0.id == id }) else { return }
        var before = activeWidgets[idx]
        var after = before
        transform(&after)
        guard before != after else { return }
        recordModify(label: label, before: before, after: after)
    }

    func beginGesture() { history.beginCoalescing() }
    func endGesture() { history.endCoalescing() }

    // MARK: - History plumbing

    var canUndo: Bool { undoLevels > 0 }
    var canRedo: Bool { redoLevels > 0 }

    func undo() {
        if history.undo(state: self) { refreshHistory() }
    }

    func redo() {
        if history.redo(state: self) { refreshHistory() }
    }

    private func refreshHistory() {
        undoLevels = history.undoCount
        redoLevels = history.redoCount
    }

    // MARK: - Project lifecycle

    func newProject(name: String, device: Device) {
        project = .new(name: name, device: device)
        selection = nil
        isAODActive = false
        zoom = 1
        runtimeImages.removeAll()
        homeVisible = false
    }

    // MARK: - Home screen / recents / import

    func refreshRecents() {
        recents = RecentsStore.load()
    }

    /// Returns to the home screen, flushing any pending autosave first.
    func goHome() {
        persistCurrentProject()
        showNewProjectSheet = false
        showWidgetEditor = false
        isExploring = false
        homeVisible = true
    }

    /// Opens the Explore screen. Home stays underneath so "Back" lands there.
    func openExplore() {
        isExploring = true
    }

    /// Debounced autosave, called on every project change (including undo).
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.persistCurrentProject()
        }
    }

    func persistCurrentProject() {
        syncImagesToProject()
        guard !project.name.isEmpty else { return }
        let record = RecentsStore.save(project: project, isImported: pendingImport ? true : nil)
        recents.removeAll { $0.id == record.id }
        recents.insert(record, at: 0)
    }

    /// Safety net: any live image data still attached to an image widget is
    /// folded into the persisted project before saving, so no imported image is
    /// lost even if it was set through an older code path.
    private func syncImagesToProject() {
        guard !project.images.isEmpty || !runtimeImages.isEmpty else { return }
        var images = project.images
        for widget in project.widgets + project.aodWidgets {
            guard widget.kind == .image || widget.kind == .imageList else { continue }
            if let data = runtimeImages[widget.id] {
                images[widget.id.uuidString] = data
            }
        }
        project.images = images
    }

    /// Brings a decoded project into the editor and makes it the most recent.
    func loadProject(_ loaded: WatchFaceProject) {
        project = loaded
        runtimeImages = Dictionary(
            uniqueKeysWithValues: loaded.images.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            }
        )
        selection = nil
        isAODActive = false
        zoom = 1
        homeVisible = false
        persistCurrentProject()
        refreshRecents()
    }

    func openRecent(_ recent: RecentProject) {
        guard let project = RecentsStore.content(of: recent) else { return }
        loadProject(project)
    }

    func importProject(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let xml = try? String(contentsOf: url, encoding: .utf8),
              let project = FprjParser.parse(xml) else { return }
        pendingImport = true
        defer { pendingImport = false }
        loadProject(project)
    }

    func refreshCompiledFaces() {
        compiledFaces = CompiledFacesStore.load()
    }

    /// Imports a compiled face (.bin / .face) from the filesystem. The binary
    /// is copied into Mirante's storage so it survives relaunches and is ready
    /// to install without re-importing.
    func importCompiledFace(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        guard let face = CompiledFacesStore.add(copying: url, name: name) else { return }
        compiledFaces.removeAll { $0.id == face.id }
        compiledFaces.insert(face, at: 0)
    }

    func removeCompiledFace(_ face: CompiledFace) {
        CompiledFacesStore.remove(face)
        compiledFaces.removeAll { $0.id == face.id }
        if pendingInstallFace?.id == face.id { pendingInstallFace = nil }
    }

    /// Set while an imported file is being loaded so the persisted recent is
    /// flagged as imported and surfaced as such in Explore.
    private var pendingImport = false

    private func uniquifyName(_ widget: inout WidgetItem) {
        var name = widget.name
        while activeWidgets.contains(where: { $0.name == name }) {
            if let space = name.lastIndex(of: " "),
               let suffix = Int(name[name.index(after: space)...]) {
                name = "\(name[..<space]) \(suffix + 1)"
            } else {
                name = "\(name) 2"
            }
        }
        widget.name = name
    }
}

struct ImageImportRequest {
    let kind: WidgetKind
}
