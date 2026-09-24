import SwiftUI

#if os(macOS)
import AppKit
#endif

#if os(macOS)
private let canvasBackground = Color(nsColor: .windowBackgroundColor)
#else
private let canvasBackground = Color(uiColor: .systemBackground)
#endif

struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1)
    static let right = ResizeEdges(rawValue: 2)
    static let top = ResizeEdges(rawValue: 4)
    static let bottom = ResizeEdges(rawValue: 8)
}

/// A drag captured on the canvas container, measured in device pixels.
struct CanvasDrag {
    enum Mode { case move, resize }
    var mode: Mode
    var widgetID: UUID
    var originX: Int
    var originY: Int
    var startW: Int
    var startH: Int
    var edges: ResizeEdges
}

/// Snap distance (device px) above which a guide line does not engage.
private let snapThreshold: CGFloat = 6
/// Maximum gap (device px) at which a spacing rail is drawn to a neighbour.
private let spacingRange: CGFloat = 100
/// Line colour for alignment guides (Figma-style magenta).
private let guideColor = Color.pink
/// Colour for the gap/spacing measurement rails.
private let railColor = Color.orange

/// A full-bleed vertical or horizontal alignment guide shown while dragging.
private struct GuideLine: Identifiable, Equatable {
    enum Axis { case vertical, horizontal }
    var id = UUID()
    var axis: Axis
    var position: CGFloat   // device px
}

/// A measurement rail drawn between the dragged widget and a neighbour,
/// showing the edge-to-edge gap ("|-gap-|").
private struct SpacingRail: Identifiable, Equatable {
    enum Axis { case vertical, horizontal }
    var id = UUID()
    var axis: Axis
    var spanStart: CGFloat  // device px along the rail axis
    var spanEnd: CGFloat
    var at: CGFloat         // device px along the orthogonal axis (overlap centre)
    var value: Int
}

/// The outcome of snapping + measuring for the widget currently being dragged.
private struct SnapResult {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var guides: [GuideLine]
    var rails: [SpacingRail]
}

struct EditorCanvasView: View {
    @Environment(EditorState.self) private var editor
    @Environment(\.colorScheme) private var colorScheme
    @State private var pinchStartZoom: CGFloat?
    @State private var activeDrag: CanvasDrag?
    @State private var isCanvasDropTarget = false
    @State private var guides: [GuideLine] = []
    @State private var spacingRails: [SpacingRail] = []

    var body: some View {
        GeometryReader { proxy in
            let screen = editor.project.screenSize
            let fitScale = max(
                min(
                    (proxy.size.width - 64) / screen.width,
                    (proxy.size.height - 64) / screen.height
                ),
                0.05
            )
            let baseSize = CGSize(width: screen.width * fitScale, height: screen.height * fitScale)
            let zoomedSize = CGSize(
                width: baseSize.width * editor.zoom,
                height: baseSize.height * editor.zoom
            )

            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Color.clear
                        .frame(width: zoomedSize.width, height: zoomedSize.height)

                    previewContent(scale: fitScale, size: baseSize, screen: screen)
                        .scaleEffect(editor.zoom, anchor: .center)
                }
                .frame(minWidth: max(proxy.size.width - 64, 0), minHeight: max(proxy.size.height - 64, 0))
                .padding(32)
                .overlay {
                    if editor.activeWidgets.isEmpty {
                        emptyHint
                    }
                }
            }
            .background(canvasBackground)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if pinchStartZoom == nil { pinchStartZoom = editor.zoom }
                        if let start = pinchStartZoom {
                            editor.zoom = max(0.2, min(4, start * value))
                        }
                    }
                    .onEnded { _ in
                        pinchStartZoom = nil
                    }
            )
#if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(_):
                    NSCursor.arrow.set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
#endif
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Watch face canvas")
            .accessibilityHint("Pinch to zoom")
        }
        .navigationTitle(editor.isAODActive ? "\(editor.project.name) — AOD" : editor.project.name)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(editor.isAODActive
                ? "No widgets in the always-on display yet. Use Add to create one."
                : "No widgets yet. Use Add to create one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .allowsHitTesting(false)
    }

    private func previewContent(scale: CGFloat, size: CGSize, screen: CGSize) -> some View {
        let radius = CGFloat(editor.project.device.radius) * scale
        return ZStack(alignment: .topLeading) {
            watchShape(scale: scale, drawSize: size)

            if editor.showGrid {
                gridOverlay(size: size, scale: scale)
            }

            ForEach(editor.activeWidgets) { widget in
                WidgetCanvasItem(
                    widget: widget,
                    scale: scale,
                    isSelected: editor.selection == widget.id
                )
                .position(
                    x: (CGFloat(widget.x) + CGFloat(widget.width) / 2) * scale,
                    y: (CGFloat(widget.y) + CGFloat(widget.height) / 2) * scale
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(Rectangle())
        .gesture(canvasDragGesture(scale: scale))
        .onTapGesture(coordinateSpace: .local) { location in
            #if os(iOS)
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
            #endif
            editor.selection = widgetOrSelected(at: location, scale: scale)?.id
        }
        .dropDestination(for: String.self) { items, location in
            guard let raw = items.first,
                  let id = UUID(uuidString: raw),
                  let widget = editor.activeWidgets.first(where: { $0.id == id }) else { return false }
            let x = Int((location.x / scale).rounded()) - widget.width / 2
            let y = Int((location.y / scale).rounded()) - widget.height / 2
            editor.repositionWidget(id, toX: x, y: y)
            return true
        } isTargeted: { isTargeted in
            isCanvasDropTarget = isTargeted
        }
        .dropDestination(for: URL.self) { items, location in
            guard let url = items.first,
                  let id = editor.importImage(at: url, kind: .image) else { return false }
            if let widget = editor.activeWidgets.first(where: { $0.id == id }) {
                let x = Int((location.x / scale).rounded()) - widget.width / 2
                let y = Int((location.y / scale).rounded()) - widget.height / 2
                editor.repositionWidget(id, toX: x, y: y)
            }
            return true
        } isTargeted: { isTargeted in
            isCanvasDropTarget = isTargeted
        }
.overlay {
            if isCanvasDropTarget {
                RoundedRectangle(
                    cornerRadius: max(2, CGFloat(editor.project.device.radius) * scale),

                    style: .continuous
                )
                .strokeBorder(.tint.opacity(0.9), style: StrokeStyle(lineWidth: 2 / max(scale, 0.01)))
            }
        }
        .overlay {
            alignmentOverlay(scale: scale, size: size)
        }
    }
    // MARK: - Move + resize (container-coordinate space, immune to feedback)

    private func canvasDragGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let dx = Int(((value.location.x - value.startLocation.x) / scale).rounded())
                let dy = Int(((value.location.y - value.startLocation.y) / scale).rounded())

                var drag = activeDrag
                if drag == nil {
                    guard let selected = widgetOrSelected(at: value.startLocation, scale: scale) else { return }
                    editor.selection = selected.id
                    let edges = handleHitTest(at: value.startLocation, widget: selected, scale: scale)
                    let mode: CanvasDrag.Mode = edges.isEmpty ? .move : .resize
                    drag = CanvasDrag(
                        mode: mode,
                        widgetID: selected.id,
                        originX: selected.x,
                        originY: selected.y,
                        startW: selected.width,
                        startH: selected.height,
                        edges: edges
                    )
                    activeDrag = drag
                    editor.beginGesture()
                }
                guard let drag else { return }
                apply(drag, dx: dx, dy: dy, scale: scale)
            }
            .onEnded { _ in
                activeDrag = nil
                guides = []
                spacingRails = []
                editor.endGesture()
            }
    }

    private func widgetOrSelected(at point: CGPoint, scale: CGFloat) -> WidgetItem? {
        for widget in editor.activeWidgets.reversed() {
            let frame = CGRect(
                x: CGFloat(widget.x) * scale,
                y: CGFloat(widget.y) * scale,
                width: CGFloat(widget.width) * scale,
                height: CGFloat(widget.height) * scale
            )
            if frame.contains(point) { return widget }
        }
        return nil
    }

    private func handleHitTest(at point: CGPoint, widget: WidgetItem, scale: CGFloat) -> ResizeEdges {
        let w = CGFloat(widget.width) * scale
        let h = CGFloat(widget.height) * scale
        let x0 = CGFloat(widget.x) * scale
        let y0 = CGFloat(widget.y) * scale
        let hh = max(10, 7 / scale) // handle hit area in device px
        var edges: ResizeEdges = []
        if abs(point.x - x0) <= hh { edges.insert(.left) }
        if abs(point.x - (x0 + w)) <= hh { edges.insert(.right) }
        if abs(point.y - y0) <= hh { edges.insert(.top) }
        if abs(point.y - (y0 + h)) <= hh { edges.insert(.bottom) }
        return edges
    }

    private func apply(_ drag: CanvasDrag, dx: Int, dy: Int, scale: CGFloat) {
        let proposed: CGRect
        switch drag.mode {
        case .move:
            // No clamping: widgets may overflow the screen and are hidden by
            // the preview's clip shape.
            proposed = CGRect(
                x: drag.originX + dx,
                y: drag.originY + dy,
                width: drag.startW,
                height: drag.startH
            )
        case .resize:
            proposed = resizeFrame(drag, dx: dx, dy: dy)
        }
        let result = snappedFrame(drag: drag, proposed: proposed)
        guides = result.guides
        spacingRails = result.rails
        editor.update({ w in
            guard w.id == drag.widgetID else { return }
            w.x = Int(result.x.rounded())
            w.y = Int(result.y.rounded())
            if drag.mode == .resize {
                w.width = Int(result.width.rounded())
                w.height = Int(result.height.rounded())
            }
        }, label: drag.mode == .move ? "Move" : "Resize")
    }

    /// Resizes a widget freely, keeping only the minimum-size rule: the widget
    /// may extend beyond every screen edge (hidden by the overflow clip).
    private func resizeFrame(_ drag: CanvasDrag, dx: Int, dy: Int) -> CGRect {
        var nx = drag.originX
        var ny = drag.originY
        var nw = drag.startW
        var nh = drag.startH
        if drag.edges.contains(.left) {
            nx = drag.originX + dx
            nw = drag.startW - dx
        } else if drag.edges.contains(.right) {
            nw = drag.startW + dx
        }
        if drag.edges.contains(.top) {
            ny = drag.originY + dy
            nh = drag.startH - dy
        } else if drag.edges.contains(.bottom) {
            nh = drag.startH + dy
        }
        if nw < 8 {
            if drag.edges.contains(.left) { nx += nw - 8 }
            nw = 8
        }
        if nh < 8 {
            if drag.edges.contains(.top) { ny += nh - 8 }
            nh = 8
        }
        return CGRect(x: CGFloat(nx), y: CGFloat(ny), width: CGFloat(nw), height: CGFloat(nh))
    }

    // MARK: - Alignment snapping + spacing measurement

    /// Reference x-lines from every other widget plus the screen bounds/centre.
    private func xAlignRefs(ignoring draggedID: UUID) -> [CGFloat] {
        var refs: [CGFloat] = []
        let screen = editor.project.screenSize
        for w in editor.activeWidgets where w.id != draggedID {
            refs += [CGFloat(w.x), CGFloat(w.x) + CGFloat(w.width) / 2, CGFloat(w.x) + CGFloat(w.width)]
        }
        refs += [0, screen.width / 2, screen.width]
        return refs
    }

    /// Reference y-lines from every other widget plus the screen bounds/centre.
    private func yAlignRefs(ignoring draggedID: UUID) -> [CGFloat] {
        var refs: [CGFloat] = []
        let screen = editor.project.screenSize
        for w in editor.activeWidgets where w.id != draggedID {
            refs += [CGFloat(w.y), CGFloat(w.y) + CGFloat(w.height) / 2, CGFloat(w.y) + CGFloat(w.height)]
        }
        refs += [0, screen.height / 2, screen.height]
        return refs
    }

    /// Chooses the candidate/reference pair closest within the snap threshold.
    private func nearestSnap(positions: [CGFloat], refs: [CGFloat]) -> (delta: CGFloat, guide: CGFloat)? {
        var best: (delta: CGFloat, guide: CGFloat)?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for position in positions {
            for ref in refs {
                let distance = abs(position - ref)
                if distance <= snapThreshold, distance < bestDistance {
                    bestDistance = distance
                    best = (ref - position, ref)
                }
            }
        }
        return best
    }

    /// Every reference line currently within the snap threshold of any of the
    /// dragged widget's positions (edges and centre). Unlike `nearestSnap`,
    /// this returns all engaged references so each alignment guide is drawn.
    private func engagingSnaps(positions: [CGFloat], refs: [CGFloat]) -> [CGFloat] {
        var engaged: [CGFloat] = []
        for position in positions {
            for ref in refs {
                if abs(position - ref) <= snapThreshold, !engaged.contains(ref) {
                    engaged.append(ref)
                }
            }
        }
        return engaged
    }

    /// Snaps the dragged widget's active edges against other widgets and the
    /// canvas, then measures the gaps to its neighbours.
    private func snappedFrame(drag: CanvasDrag, proposed: CGRect) -> SnapResult {
        let xRefs = xAlignRefs(ignoring: drag.widgetID)
        let yRefs = yAlignRefs(ignoring: drag.widgetID)
        var x = proposed.minX
        var y = proposed.minY
        var w = proposed.width
        var h = proposed.height
        var guides: [GuideLine] = []

        switch drag.mode {
        case .move:
            let xPositions = [x, x + w / 2, x + w]
            let yPositions = [y, y + h / 2, y + h]
            if let hit = nearestSnap(positions: xPositions, refs: xRefs) {
                x += hit.delta
            }
            if let hit = nearestSnap(positions: yPositions, refs: yRefs) {
                y += hit.delta
            }
            // Draw every engaged reference (edges, centres, screen bounds) as
            // a guide line, so centre-to-centre alignment is visible alongside
            // the existing edge guides while the widget is dragged.
            for ref in engagingSnaps(positions: xPositions, refs: xRefs) {
                guides.append(GuideLine(axis: .vertical, position: ref))
            }
            for ref in engagingSnaps(positions: yPositions, refs: yRefs) {
                guides.append(GuideLine(axis: .horizontal, position: ref))
            }
        case .resize:
            let oldMaxX = x + w
            let oldMaxY = y + h
            if drag.edges.contains(.left) {
                if let hit = nearestSnap(positions: [x], refs: xRefs) {
                    let newX = x + hit.delta
                    if oldMaxX - newX >= 8 {
                        x = newX
                        w = oldMaxX - x
                        guides.append(GuideLine(axis: .vertical, position: hit.guide))
                    }
                }
            } else if drag.edges.contains(.right) {
                if let hit = nearestSnap(positions: [oldMaxX], refs: xRefs) {
                    let newMaxX = oldMaxX + hit.delta
                    if newMaxX - x >= 8 {
                        w = newMaxX - x
                        guides.append(GuideLine(axis: .vertical, position: hit.guide))
                    }
                }
            }
            if drag.edges.contains(.top) {
                if let hit = nearestSnap(positions: [y], refs: yRefs) {
                    let newY = y + hit.delta
                    if oldMaxY - newY >= 8 {
                        y = newY
                        h = oldMaxY - y
                        guides.append(GuideLine(axis: .horizontal, position: hit.guide))
                    }
                }
            } else if drag.edges.contains(.bottom) {
                if let hit = nearestSnap(positions: [oldMaxY], refs: yRefs) {
                    let newMaxY = oldMaxY + hit.delta
                    if newMaxY - y >= 8 {
                        h = newMaxY - y
                        guides.append(GuideLine(axis: .horizontal, position: hit.guide))
                    }
                }
            }
        }

        let final = CGRect(x: x, y: y, width: w, height: h)
        return SnapResult(
            x: x, y: y, width: w, height: h,
            guides: guides,
            rails: spacingRails(for: final, ignoring: drag.widgetID)
        )
    }

    /// Measures edge-to-edge gaps between the dragged frame and neighbours
    /// within `spacingRange`, one rail per overlapping band.
    private func spacingRails(for frame: CGRect, ignoring draggedID: UUID) -> [SpacingRail] {
        var rails: [SpacingRail] = []
        for widget in editor.activeWidgets where widget.id != draggedID {
            let other = CGRect(
                x: CGFloat(widget.x), y: CGFloat(widget.y),
                width: CGFloat(widget.width), height: CGFloat(widget.height)
            )
            // Side-by-side neighbours (gap along x) share a vertical band.
            if frame.minY < other.maxY, frame.maxY > other.minY {
                if other.minX > frame.maxX, other.minX - frame.maxX <= spacingRange {
                    rails.append(SpacingRail(
                        axis: .horizontal,
                        spanStart: frame.maxX,
                        spanEnd: other.minX,
                        at: verticalOverlapCenter(frame, other),
                        value: Int((other.minX - frame.maxX).rounded())
                    ))
                } else if frame.minX > other.maxX, frame.minX - other.maxX <= spacingRange {
                    rails.append(SpacingRail(
                        axis: .horizontal,
                        spanStart: other.maxX,
                        spanEnd: frame.minX,
                        at: verticalOverlapCenter(frame, other),
                        value: Int((frame.minX - other.maxX).rounded())
                    ))
                }
            }
            // Stacked neighbours (gap along y) share a horizontal band.
            if frame.minX < other.maxX, frame.maxX > other.minX {
                if other.minY > frame.maxY, other.minY - frame.maxY <= spacingRange {
                    rails.append(SpacingRail(
                        axis: .vertical,
                        spanStart: frame.maxY,
                        spanEnd: other.minY,
                        at: horizontalOverlapCenter(frame, other),
                        value: Int((other.minY - frame.maxY).rounded())
                    ))
                } else if frame.minY > other.maxY, frame.minY - other.maxY <= spacingRange {
                    rails.append(SpacingRail(
                        axis: .vertical,
                        spanStart: other.maxY,
                        spanEnd: frame.minY,
                        at: horizontalOverlapCenter(frame, other),
                        value: Int((frame.minY - other.maxY).rounded())
                    ))
                }
            }
        }
        return rails.sorted { $0.value < $1.value }
    }

    private func verticalOverlapCenter(_ a: CGRect, _ b: CGRect) -> CGFloat {
        (max(a.minY, b.minY) + min(a.maxY, b.maxY)) / 2
    }

    private func horizontalOverlapCenter(_ a: CGRect, _ b: CGRect) -> CGFloat {
        (max(a.minX, b.minX) + min(a.maxX, b.maxX)) / 2
    }

    private func watchShape(scale: CGFloat, drawSize: CGSize) -> some View {
        let radius = CGFloat(editor.project.device.radius) * scale
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.black)
            .frame(width: drawSize.width, height: drawSize.height)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.3 : 0.2), lineWidth: 1)
            }
    }

    private func gridOverlay(size: CGSize, scale: CGFloat) -> some View {
        let step: CGFloat = 50 * scale
        return Canvas { context, _ in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    // MARK: - Alignment guides overlay (drawn only while dragging)

    private func alignmentOverlay(scale: CGFloat, size: CGSize) -> some View {
        let unit = 1 / max(scale * editor.zoom, 0.01)
        return ZStack {
            ForEach(guides) { guide in
                if guide.axis == .vertical {
                    Rectangle()
                        .fill(guideColor)
                        .frame(width: 1.5 * unit, height: size.height)
                        .position(x: guide.position * scale, y: size.height / 2)
                } else {
                    Rectangle()
                        .fill(guideColor)
                        .frame(width: size.width, height: 1.5 * unit)
                        .position(x: size.width / 2, y: guide.position * scale)
                }
            }
            ForEach(spacingRails) { rail in
                SpacingRailView(rail: rail, scale: scale, zoom: editor.zoom)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Draws a measurement rail with end ticks and a gap value label
/// between two widget edges ("|-gap-|").
private struct SpacingRailView: View {
    let rail: SpacingRail
    let scale: CGFloat
    let zoom: CGFloat

    private var unit: CGFloat { 1 / max(scale * zoom, 0.01) }
    private var thickness: CGFloat { 1.5 * unit }
    private var tick: CGFloat { 5 * unit }

    var body: some View {
        ZStack {
            Path { path in
                if rail.axis == .horizontal {
                    let y = rail.at * scale
                    let x0 = rail.spanStart * scale
                    let x1 = rail.spanEnd * scale
                    path.move(to: CGPoint(x: x0, y: y))
                    path.addLine(to: CGPoint(x: x1, y: y))
                    path.move(to: CGPoint(x: x0, y: y - tick))
                    path.addLine(to: CGPoint(x: x0, y: y + tick))
                    path.move(to: CGPoint(x: x1, y: y - tick))
                    path.addLine(to: CGPoint(x: x1, y: y + tick))
                } else {
                    let x = rail.at * scale
                    let y0 = rail.spanStart * scale
                    let y1 = rail.spanEnd * scale
                    path.move(to: CGPoint(x: x, y: y0))
                    path.addLine(to: CGPoint(x: x, y: y1))
                    path.move(to: CGPoint(x: x - tick, y: y0))
                    path.addLine(to: CGPoint(x: x + tick, y: y0))
                    path.move(to: CGPoint(x: x - tick, y: y1))
                    path.addLine(to: CGPoint(x: x + tick, y: y1))
                }
            }
            .stroke(railColor, lineWidth: thickness)

            Text("\(rail.value)")
                .font(.system(size: 11 * unit, weight: .semibold).monospacedDigit())
                .foregroundStyle(railColor)
                .padding(.horizontal, 4 * unit)
                .padding(.vertical, 1 * unit)
                .background(railColor.opacity(0.2), in: Capsule())
                .position(labelPosition)
        }
        .allowsHitTesting(false)
    }

    private var labelPosition: CGPoint {
        let mid = (rail.spanStart + rail.spanEnd) / 2 * scale
        if rail.axis == .horizontal {
            return CGPoint(x: mid, y: rail.at * scale - 11 * unit)
        }
        return CGPoint(x: rail.at * scale + 26 * unit, y: mid)
    }
}

struct WidgetCanvasItem: View {
    @Environment(EditorState.self) private var editor
    let widget: WidgetItem
    let scale: CGFloat
    let isSelected: Bool

    var body: some View {
        let width = CGFloat(widget.width) * scale
        let height = CGFloat(widget.height) * scale
        let opacity = Double(widget.alpha) / 255 * (widget.visible ? 1 : 0.35)

        WidgetPreviewView(widget: widget, scale: scale, deviceID: editor.project.deviceID, images: editor.project.images)
            .opacity(opacity)
            .frame(width: width, height: height)
            .overlay {
                if isSelected {
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3 / max(scale, 0.01)))
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5 / max(scale, 0.01)))
                        resizeHandles
                        if widget.kind == .polyline {
                            polylineEditingOverlay(width: width, height: height)
                        }
                    }
                }
            }
            .coordinateSpace(name: polylineEditSpaceName)
            .contentShape(Rectangle())
    }

    // MARK: - On-canvas polyline editing

    private func polylineEditingOverlay(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.clear
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            // Add a point only when tapping close to the drawn
                            // line; taps elsewhere fall through so the widget
                            // can still be selected/moved without editing.
                            let points = widget.pointList.map { point in
                                CGPoint(x: point.x * width, y: point.y * height)
                            }
                            guard let nearest = nearestPolylinePoint(
                                to: value.location,
                                segments: points,
                                threshold: max(16, 10 / max(scale, 0.01))
                            ) else { return }
                            editor.insertPolylinePoint(widget.id, at: CGPoint(
                                x: min(max(nearest.x / max(width, 1), 0), 1),
                                y: min(max(nearest.y / max(height, 1), 0), 1)
                            ))
                        }
                )
            if widget.isValueFilledPolyline {
                PolylineTopMarker(widget: widget, width: width, height: height)
            }
            ForEach(widget.pointList.indices, id: \.self) { index in
                PolylinePointHandle(
                    widget: widget,
                    index: index,
                    width: width,
                    height: height
                )
            }
            PolylineRotationHandle(widget: widget, width: width, height: height, scale: scale)
        }
        .allowsHitTesting(widget.kind == .polyline)
    }

    /// Returns the point on the nearest segment within `threshold` device px
    /// (the projected spot), or nil when every segment is too far away.
    private func nearestPolylinePoint(to tap: CGPoint, segments: [CGPoint], threshold: CGFloat) -> CGPoint? {
        guard segments.count >= 2 else { return nil }
        var best: CGPoint?
        var bestDistance = threshold
        for i in 0..<(segments.count - 1) {
            let a = segments[i], b = segments[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t: CGFloat = 0
            if len2 > 0 {
                t = max(0, min(1, ((tap.x - a.x) * dx + (tap.y - a.y) * dy) / len2))
            }
            let spot = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = hypot(spot.x - tap.x, spot.y - tap.y)
            if distance < bestDistance {
                bestDistance = distance
                best = spot
            }
        }
        return best
    }

    private var resizeHandles: some View {
        let e: CGFloat = 8
        let w = CGFloat(widget.width) * scale
        let h = CGFloat(widget.height) * scale
        let centers: [(CGPoint, ResizeEdges)] = [
            (CGPoint(x: 0, y: 0), [.left, .top]),
            (CGPoint(x: w / 2, y: 0), [.top]),
            (CGPoint(x: w, y: 0), [.right, .top]),
            (CGPoint(x: w, y: h / 2), [.right]),
            (CGPoint(x: w, y: h), [.right, .bottom]),
            (CGPoint(x: w / 2, y: h), [.bottom]),
            (CGPoint(x: 0, y: h), [.left, .bottom]),
            (CGPoint(x: 0, y: h / 2), [.left]),
        ]
        return ZStack {
            ForEach(Array(centers.enumerated()), id: \.offset) { _, item in
                let size = item.0
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tint)
                    .frame(width: e, height: e)
                    .overlay {
                        RoundedRectangle(cornerRadius: 1.5)
                            .strokeBorder(.white, lineWidth: 0.75)
                    }
                    .position(
                        x: size.x,
                        y: size.y
                    )
            }
        }
    }
}

/// The coordinate space (a selected widget) used to convert polyline point
/// drags and taps into widget-local coordinates.
private let polylineEditSpaceName = "mirante.polyline-edit"

private struct PolylinePointHandle: View {
    @Environment(EditorState.self) private var editor
    let widget: WidgetItem
    let index: Int
    let width: CGFloat
    let height: CGFloat

    @State private var isDragging = false

    var body: some View {
        let point = widget.pointList[index]
        Circle()
            .fill(.tint)
            .frame(width: 14, height: 14)
            .overlay {
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            .position(x: point.x * width, y: point.y * height)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(polylineEditSpaceName))
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            editor.beginGesture()
                        }
                        editor.updatePolylinePoint(
                            widget.id,
                            index: index,
                            to: CGPoint(
                                x: min(max(value.location.x / max(width, 1), 0), 1),
                                y: min(max(value.location.y / max(height, 1), 0), 1)
                            )
                        )
                    }
                    .onEnded { _ in
                        if isDragging {
                            isDragging = false
                            editor.endGesture()
                        }
                    }
            )
    }
}

/// A small marker drawn at the "top" end of a value-filled polyline, so the
/// user can read which way the value fills. It rotates with the widget.
private struct PolylineTopMarker: View {
    let widget: WidgetItem
    let width: CGFloat
    let height: CGFloat

    private var rotationRadians: CGFloat { CGFloat(widget.rotation) * .pi / 180 }

    var body: some View {
        let center = CGPoint(x: width / 2, y: height / 2)
        let p = widget.polylineTopEndpoint
        let local = CGPoint(x: p.x * width, y: p.y * height)
        let cos = cos(rotationRadians), sin = sin(rotationRadians)
        let rotated = CGPoint(
            x: center.x + (local.x - center.x) * cos - (local.y - center.y) * sin,
            y: center.y + (local.x - center.x) * sin + (local.y - center.y) * cos
        )
        Triangle()
            .fill(Color.yellow)
            .frame(width: 10, height: 7)
            .position(rotated + CGPoint(x: 0, y: -10))
            .allowsHitTesting(false)
    }
}

/// The corner rotation handle: floats above the selected polyline, follows its
/// rotation, and dragging it spins the widget around its center.
private struct PolylineRotationHandle: View {
    @Environment(EditorState.self) private var editor
    let widget: WidgetItem
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat

    @State private var isDragging = false
    @State private var startRotation = 0.0
    @State private var startAngle = 0.0

    private var unit: CGFloat { 1 / max(scale, 0.01) }

    var body: some View {
        let cx = width / 2
        let cy = height / 2
        let radius = height / 2 + 26 * unit
        let theta = CGFloat(widget.rotation) * .pi / 180
        let position = CGPoint(x: cx + sin(theta) * radius, y: cy - cos(theta) * radius)
        return RoundedRectangle(cornerRadius: 4)
            .fill(.tint)
            .frame(width: 22, height: 22)
            .overlay {
                Image(systemName: "rotate.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(polylineEditSpaceName))
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            startRotation = widget.rotation
                            startAngle = atan2(value.location.y - cy, value.location.x - cx)
                            editor.beginGesture()
                        }
                        let angle = atan2(value.location.y - cy, value.location.x - cx)
                        var delta = (angle - startAngle) * 180 / .pi
                        delta = (delta + 180).truncatingRemainder(dividingBy: 360) - 180
                        let newRotation = (startRotation + delta).rounded()
                        editor.update({ w in
                            guard w.id == widget.id else { return }
                            w.rotation = newRotation
                        }, label: "Rotate")
                    }
                    .onEnded { _ in
                        if isDragging {
                            isDragging = false
                            editor.endGesture()
                        }
                    }
            )
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}