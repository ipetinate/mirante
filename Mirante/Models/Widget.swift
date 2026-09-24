import Foundation
import SwiftUI

enum WidgetKind: String, CaseIterable, Identifiable, Codable {
    case image
    case imageList
    case digitalNumber
    case analog
    case arc
    case container
    case pointer
    case polyline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .image: return String(localized: "Image")
        case .imageList: return String(localized: "Image List")
        case .digitalNumber: return String(localized: "Digital Number")
        case .analog: return String(localized: "Analog Display")
        case .arc: return String(localized: "Arc Progress")
        case .container: return String(localized: "Container")
        case .pointer: return String(localized: "Pointer")
        case .polyline: return String(localized: "Polyline")
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .imageList: return "photo.stack"
        case .digitalNumber: return "textformat.123"
        case .analog: return "clock"
        case .arc: return "chart.bar"
        case .container: return "square.dashed"
        case .pointer: return "location.north.fill"
        case .polyline: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// Numeric @Shape value used in the fprj format.
    var fprjShape: Int {
        switch self {
        case .analog: return 27
        case .arc: return 42
        case .image: return 30
        case .imageList: return 31
        case .digitalNumber: return 32
        case .container: return 34
        case .pointer: return 27
        case .polyline: return 33
        }
    }

    /// Whether the widget draws itself with a user-selectable color.
    var usesColor: Bool {
        switch self {
        case .arc, .polyline, .digitalNumber, .container: return true
        default: return false
        }
    }

    /// Whether adding this kind makes sense for the project's format.
    func isAddable(for format: ProjectFormat) -> Bool {
        if format == .gmf {
            return self != .analog && self != .arc && self != .container
        }
        return self != .pointer
    }
}

struct WidgetItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var kind: WidgetKind
    var name: String

    // Geometry (device pixel space)
    var x: Int = 0
    var y: Int = 0
    var width: Int = 100
    var height: Int = 100
    var alpha: Int = 255
    var visible: Bool = true
    var visibleSourceID: String = "0"

    // Image / image list
    var bitmap: String = ""
    var bitmapList: [String] = []
    var indexSourceID: String = "0"
    var defaultIndex: Int = 0
    var radius: Int = 0

    // Digital number
    var valueSourceID: String = "8"
    var digits: Int = 2
    var spacing: Int = 0
    var alignment: Int = 0
    /// Draws a translucent rounded box behind the digits (removable).
    var digitBackground: Bool = true

    // Analog
    var hourHandImage: String = ""
    var minuteHandImage: String = ""
    var secondHandImage: String = ""
    var background: String = ""
    var foreground: String = ""
    var rotateCenterX: Int = 0
    var rotateCenterY: Int = 0

    // Arc progress
    var arcStartAngle: Double = -90
    var arcEndAngle: Double = 270
    var arcLineWidth: Int = 8
    var rangeMin: Int = 0
    var rangeMax: Int = 100

    // Pointer (GMF-style)
    var pointerImage: String = ""
    var pointerAnchorX: Double = 0.5
    var pointerAnchorY: Double = 0.5

    // Polyline (free-form line)
    var pointList: [CGPoint] = [
        CGPoint(x: 0.0, y: 0.5),
        CGPoint(x: 1.0, y: 0.5)
    ]
    var lineWidth: Int = 6
    /// Whether the polyline is used as a value bar: only a fraction of the
    /// line (driven by `valueSourceID` against `rangeMin`/`rangeMax`) is drawn.
    var polylineFilled: Bool = false
    /// 0 = fills bottom-to-top ("up"), 1 = fills top-to-bottom ("down").
    var polylineFillDirection: Int = 0
    /// Rotation of the whole widget in degrees, clockwise, about its center.
    var rotation: Double = 0

    // Appearance (RGB, 0-255 each)
    var colorR: Int = 255
    var colorG: Int = 255
    var colorB: Int = 255

    var widgetColor: Color {
        Color(
            red: Double(colorR) / 255,
            green: Double(colorG) / 255,
            blue: Double(colorB) / 255
        )
    }

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Polyline value fill

extension WidgetItem {
    /// Whether this widget renders as a value-filled polyline.
    var isValueFilledPolyline: Bool {
        kind == .polyline && polylineFilled && pointList.count >= 2 && valueSourceID != "0"
    }

    /// The most topmost endpoint of the polyline, in widget-local space.
    /// Used as an editor indicator for the fill direction.
    var polylineTopEndpoint: CGPoint {
        guard let first = pointList.first, let last = pointList.last else { return .zero }
        if last.y < first.y - 0.001 { return last }
        if first.y < last.y - 0.001 { return first }
        return last.x < first.x ? last : first
    }

    /// Computes the fraction of the polyline path (along its length) that the
    /// value fill should cover, anchored at the bottom or top end depending on
    /// `polylineFillDirection`.
    /// - Parameter progress: filled fraction, clamped to 0...1.
    /// - Returns: the path trim interval `(from, to)`.
    func polylineValueTrim(progress: CGFloat) -> (from: CGFloat, to: CGFloat) {
        let first = pointList.first ?? .zero
        let last = pointList.last ?? .zero
        let p = min(max(progress, 0), 1)
        // "bottom" is the endpoint nearer the widget's bottom (larger y).
        let bottomFirst = (last.y < first.y - 0.001)
            || (abs(first.y - last.y) <= 0.001 && last.x < first.x - 0.001)
        let anchoredAtBottom = polylineFillDirection == 0
        // The anchored end is at path parameter 0 when it is the first point.
        let anchoredFirst = bottomFirst == anchoredAtBottom
        if anchoredFirst {
            return (0, p)
        }
        return (1 - p, 1)
    }
}
