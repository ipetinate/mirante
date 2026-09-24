import ImageIO
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders a scaled-down, live-looking preview of the face using simulated
/// data-source values.
struct LivePreviewView: View {
    @Environment(EditorState.self) private var editor
    var widgets: [WidgetItem]
    var screen: CGSize
    var device: Device?
    /// Image data for the previewed widgets (used when previewing a project
    /// that is not the live editor, e.g. Explore). Defaults to the editor's own
    /// data when omitted.
    var images: [String: Data] = [:]

    private var shapeDevice: Device { device ?? editor.project.device }
    private var target: CGSize { shapeDevice.previewSize }

    var body: some View {
        GeometryReader { proxy in
            let avail = CGSize(
                width: max(proxy.size.width - 12, 1),
                height: max(proxy.size.height - 12, 1)
            )
            let fitScale = min(
                target.width / max(screen.width, 1),
                target.height / max(screen.height, 1)
            )
            let availScale = min(
                avail.width / max(screen.width, 1),
                avail.height / max(screen.height, 1)
            )
            let scale = min(fitScale, availScale)
            let drawSize = CGSize(width: screen.width * scale, height: screen.height * scale)
            let radius = CGFloat(shapeDevice.radius) * scale

            ZStack(alignment: .topLeading) {
                ForEach(widgets) { widget in
                    if widget.visible {
                        WidgetPreviewView(widget: widget, scale: scale, deviceID: shapeDevice.id, images: images)
                            .position(
                                x: (CGFloat(widget.x) + CGFloat(widget.width) / 2) * scale,
                                y: (CGFloat(widget.y) + CGFloat(widget.height) / 2) * scale
                            )
                            .frame(
                                width: CGFloat(widget.width) * scale,
                                height: CGFloat(widget.height) * scale
                            )
                    }
                }
            }
            .frame(width: drawSize.width, height: drawSize.height)
            .background(Color.black, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: radius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: radius,
                    style: .continuous
                )
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

struct WidgetPreviewView: View {
    @Environment(EditorState.self) private var editor
    let widget: WidgetItem
    let scale: CGFloat
    let deviceID: String
    /// Image data specific to the project being previewed; falls back to the
    /// editor's live/persisted data when empty.
    var images: [String: Data] = [:]

    var body: some View {
        switch widget.kind {
        case .image:
            imageView
                .clipShape(RoundedRectangle(cornerRadius: imageRadius, style: .continuous))
        case .imageList:
            imageView
                .clipShape(RoundedRectangle(cornerRadius: imageRadius, style: .continuous))
        case .digitalNumber:
            numberView
        case .analog:
            analogView
        case .arc:
            arcView
        case .container:
            containerView
        case .pointer:
            placeholder
        case .polyline:
            polylineView
        }
    }

    private var imageRadius: CGFloat {
        max(0, CGFloat(widget.radius) * scale)
    }

    /// The user-imported image, or a placeholder when none is attached yet.
    @ViewBuilder private var imageView: some View {
        if let data = images[widget.id.uuidString] ?? editor.imageData(for: widget.id),
           let cg = rasterData(data) {
            cg
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .opacity(Double(widget.alpha) / 255)
        } else {
            placeholder
        }
    }

    private func rasterData(_ data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        #if os(macOS)
        let size = NSSize(width: cg.width, height: cg.height)
        return Image(nsImage: NSImage(cgImage: cg, size: size))
        #else
        return Image(uiImage: UIImage(cgImage: cg))
        #endif
    }

    private var sourceValue: String {
        DataSourceCatalog.previewValue(forSourceID: widget.valueSourceID, deviceID: deviceID)
    }

    private var numberView: some View {
        ZStack {
            if widget.digitBackground {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.35))
            }
            Text(sourceValue)
                .font(.system(size: max(8, CGFloat(widget.height) * scale * 0.8), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(widget.widgetColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(Double(widget.alpha) / 255)
    }

    private var analogView: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            let seconds = Double(DataSourceCatalog.previewValue(forSourceID: "10", deviceID: deviceID)) ?? 56
            let angle = Angle.degrees(seconds * 6)
            Capsule()
                .fill(.red)
                .frame(width: 2 * scale, height: CGFloat(widget.height) * scale * 0.4)
                .offset(y: -CGFloat(widget.height) * scale * 0.2)
                .rotationEffect(angle)
        }
        .opacity(Double(widget.alpha) / 255)
    }

    private var arcView: some View {
        let value = Double(sourceValue) ?? 0
        let clamped = min(max(value, Double(widget.rangeMin)), Double(widget.rangeMax))
        let progress = widget.rangeMax > widget.rangeMin
            ? (clamped - Double(widget.rangeMin)) / Double(widget.rangeMax - widget.rangeMin)
            : 0
        let sweep = (widget.arcEndAngle - widget.arcStartAngle) * progress
        return ZStack {
            Circle()
                .trim(from: 0, to: (widget.arcEndAngle - widget.arcStartAngle) / 360)
                .stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: max(1, CGFloat(widget.arcLineWidth) * scale)))
                .rotationEffect(.degrees(widget.arcStartAngle - 90))
            Circle()
                .trim(from: 0, to: max(0, sweep) / 360)
                .stroke(widget.widgetColor, style: StrokeStyle(lineWidth: max(1, CGFloat(widget.arcLineWidth) * scale), lineCap: .round))
                .rotationEffect(.degrees(widget.arcStartAngle - 90))
        }
        .opacity(Double(widget.alpha) / 255)
    }

    private var containerView: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(widget.widgetColor.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .opacity(Double(widget.alpha) / 255)
    }

    private var polylineView: some View {
        GeometryReader { geo in
            let fullPath = polylinePath(size: geo.size)
            ZStack {
                if widget.isValueFilledPolyline {
                    let value = Double(sourceValue) ?? 0
                    let clamped = min(max(value, Double(widget.rangeMin)), Double(widget.rangeMax))
                    let progress = widget.rangeMax > widget.rangeMin
                        ? (clamped - Double(widget.rangeMin)) / Double(widget.rangeMax - widget.rangeMin)
                        : 0
                    let trim = widget.polylineValueTrim(progress: progress)
                    fullPath.stroke(
                        .white.opacity(0.2),
                        style: StrokeStyle(lineWidth: max(1, CGFloat(widget.lineWidth) * scale), lineCap: .round, lineJoin: .round)
                    )
                    fullPath
                        .trimmedPath(from: trim.from, to: trim.to)
                        .stroke(
                            widget.widgetColor,
                            style: StrokeStyle(lineWidth: max(1, CGFloat(widget.lineWidth) * scale), lineCap: .round, lineJoin: .round)
                        )
                } else {
                    fullPath.stroke(
                        widget.widgetColor,
                        style: StrokeStyle(lineWidth: max(1, CGFloat(widget.lineWidth) * scale), lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .rotationEffect(.degrees(widget.rotation), anchor: .center)
        }
        .opacity(Double(widget.alpha) / 255)
    }

    /// Builds the full polyline path in widget-local points.
    private func polylinePath(size: CGSize) -> Path {
        var path = Path()
        guard let first = widget.pointList.first else { return path }
        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
        for p in widget.pointList.dropFirst() {
            path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
        }
        return path
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.white.opacity(0.15))
            .overlay {
                Image(systemName: widget.kind.systemImage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .opacity(Double(widget.alpha) / 255)
    }
}
