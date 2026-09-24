import Foundation

/// Serializes a project into the fprj (EasyFace) XML document shape.
/// Written from the public format description — original implementation.
enum FprjExporter {
    static func export(_ project: WatchFaceProject) -> String {
        var xml = ""
        xml += "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<FaceProject"
        xml += " Name=\"\(escape(project.name))\""
        xml += " DeviceType=\"\(escape(project.deviceID))\""
        xml += " Width=\"\(project.device.width)\""
        xml += " Height=\"\(project.device.height)\""
        xml += ">\n"
        xml += screenXML(title: "main", widgets: project.widgets, project: project)
        if project.usesAOD {
            xml += screenXML(title: "aod", widgets: project.aodWidgets, project: project)
        }
        xml += "</FaceProject>\n"
        return xml
    }

    private static func screenXML(title: String, widgets: [WidgetItem], project: WatchFaceProject) -> String {
        var xml = "  <Screen Name=\"\(title)\">\n"
        for widget in widgets {
            xml += widgetXML(widget, project: project)
        }
        xml += "  </Screen>\n"
        return xml
    }

    private static func widgetXML(_ w: WidgetItem, project: WatchFaceProject) -> String {
        var attrs: [(String, String)] = []
        attrs.append(("@Shape", String(w.kind.fprjShape)))
        attrs.append(("@Name", w.name))
        attrs.append(("@X", String(w.x)))
        attrs.append(("@Y", String(w.y)))
        attrs.append(("@Width", String(w.width)))
        attrs.append(("@Height", String(w.height)))
        attrs.append(("@Alpha", String(w.alpha)))
        attrs.append(("@Visible_Src", w.visible ? w.visibleSourceID : "-1"))
        attrs.append(("@Id", w.id.uuidString))
        if w.radius > 0 {
            attrs.append(("@Radius", String(w.radius)))
        }

        switch w.kind {
        case .image:
            attrs.append(("@Bitmap", w.bitmap))
        case .imageList:
            attrs.append(("@BitmapList", w.bitmapList.joined(separator: ",")))
            attrs.append(("@Index_Src", w.indexSourceID))
            attrs.append(("@DefaultIndex", String(w.defaultIndex)))
        case .digitalNumber:
            attrs.append(("@Value_Src", w.valueSourceID))
            attrs.append(("@Digits", String(w.digits)))
            attrs.append(("@Spacing", String(w.spacing)))
            attrs.append(("@Alignment", String(w.alignment)))
            attrs.append(("@Digit_Background", w.digitBackground ? "1" : "0"))
        case .analog:
            if !w.hourHandImage.isEmpty { attrs.append(("@HourHand_ImageName", w.hourHandImage)) }
            if !w.minuteHandImage.isEmpty { attrs.append(("@MinuteHand_ImageName", w.minuteHandImage)) }
            if !w.secondHandImage.isEmpty { attrs.append(("@SecondHand_ImageName", w.secondHandImage)) }
            if !w.background.isEmpty { attrs.append(("@Background_ImageName", w.background)) }
            if !w.foreground.isEmpty { attrs.append(("@Foreground_ImageName", w.foreground)) }
            attrs.append(("@Rotate_xc", String(w.rotateCenterX)))
            attrs.append(("@Rotate_yc", String(w.rotateCenterY)))
        case .arc:
            attrs.append(("@Value_Src", w.valueSourceID))
            attrs.append(("@StartAngle", String(format: "%.1f", w.arcStartAngle)))
            attrs.append(("@EndAngle", String(format: "%.1f", w.arcEndAngle)))
            attrs.append(("@Line_Width", String(w.arcLineWidth)))
            attrs.append(("@Range_Min", String(w.rangeMin)))
            attrs.append(("@Range_Max", String(w.rangeMax)))
        case .container:
            attrs.append(("@DeviceType", project.deviceID))
        case .pointer:
            attrs.append(("@Bitmap", w.pointerImage))
            attrs.append(("@Value_Src", w.valueSourceID))
            attrs.append(("@Rotate_xc", String(Int(Double(w.width) * w.pointerAnchorX))))
            attrs.append(("@Rotate_yc", String(Int(Double(w.height) * w.pointerAnchorY))))
        case .polyline:
            attrs.append(("@Line_Width", String(w.lineWidth)))
            attrs.append(("@Points", w.pointList.map {
                String(format: "%.0f,%.0f", $0.x * 100, $0.y * 100)
            }.joined(separator: " ")))
            attrs.append(("@Fill_Direction", String(w.polylineFillDirection)))
            attrs.append(("@Rotation", String(format: "%.1f", w.rotation)))
            if w.polylineFilled {
                attrs.append(("@Fill_Value", "1"))
                attrs.append(("@Value_Src", w.valueSourceID))
                attrs.append(("@Range_Min", String(w.rangeMin)))
                attrs.append(("@Range_Max", String(w.rangeMax)))
            }
        }

        if w.kind.usesColor {
            let r = Swift.min(Swift.max(w.colorR, 0), 255)
            let g = Swift.min(Swift.max(w.colorG, 0), 255)
            let b = Swift.min(Swift.max(w.colorB, 0), 255)
            attrs.append(("@Color", String(format: "%02X%02X%02X", r, g, b)))
        }

        let attrString = attrs.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ")
        return "    <Widget \(attrString) />\n"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension WatchFaceProject {
    func exportData() -> Data {
        Data(FprjExporter.export(self).utf8)
    }

    var suggestedFileName: String {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return "\(safe).fprj"
    }
}

/// Reads back the fprj (EasyFace) XML-shaped document produced by
/// `FprjExporter` — and any file in the same shape. EasyFace uses
/// `@Name="value"` style attributes, which are not valid XML ("@" cannot
/// start a name), so this deliberately does not use `XMLParser`. Only the
/// subset Mirante writes is fully understood; unknown widgets are kept as
/// `.image` so nothing is destroyed on re-export.
enum FprjParser {
    private static let elementRegex = try! NSRegularExpression(
        pattern: #"<(FaceProject|Screen|Widget)([^>]*?)(/?)>"#
    )
    private static let attributeRegex = try! NSRegularExpression(
        pattern: #"(@?[A-Za-z0-9_]+)="([^"]*)""#
    )

    static func parse(_ xml: String) -> WatchFaceProject? {
        var deviceID = ""
        var projectName = ""
        var screen: String?
        var mainWidgets: [WidgetItem] = []
        var aodWidgets: [WidgetItem] = []
        var anyWidgetParsed = false

        let ns = xml as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in elementRegex.matches(in: xml, range: range) {
            let tag = ns.substring(with: match.range(at: 1))
            let attrsText = ns.substring(with: match.range(at: 2))
            let attrs = attributes(from: attrsText)

            switch tag {
            case "FaceProject":
                projectName = attrs["Name"] ?? ""
                deviceID = attrs["DeviceType"] ?? ""
            case "Screen":
                screen = attrs["Name"] ?? "main"
            case "Widget":
                guard let screen else { continue }
                anyWidgetParsed = true
                let widget = makeWidget(attributes: attrs)
                if screen == "aod" {
                    aodWidgets.append(widget)
                } else {
                    mainWidgets.append(widget)
                }
            default:
                break
            }
        }

        guard anyWidgetParsed, let device = Device.find(deviceID) else { return nil }
        var project = WatchFaceProject(name: projectName, deviceID: device.id)
        project.widgets = mainWidgets
        if !aodWidgets.isEmpty {
            project.usesAOD = true
            project.aodWidgets = aodWidgets
        }
        return project
    }

    private static func attributes(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in attributeRegex.matches(in: text, range: range) {
            let rawKey = ns.substring(with: match.range(at: 1))
            let key = rawKey.hasPrefix("@") ? String(rawKey.dropFirst()) : rawKey
            let value = unescape(ns.substring(with: match.range(at: 2)))
            result[key] = value
        }
        return result
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func makeWidget(attributes attr: [String: String]) -> WidgetItem {
        let shape = Int(attr["Shape"] ?? "") ?? 0
        var widget = WidgetItem(kind: kind(forShape: shape, attributes: attr), name: attr["Name"] ?? "")
        widget.x = int(attr["X"]) ?? 0
        widget.y = int(attr["Y"]) ?? 0
        widget.width = int(attr["Width"]) ?? 100
        widget.height = int(attr["Height"]) ?? 100
        widget.alpha = int(attr["Alpha"]) ?? 255
        widget.visibleSourceID = attr["Visible_Src"] ?? "0"
        widget.visible = widget.visibleSourceID != "-1"
        if widget.visibleSourceID == "-1" { widget.visibleSourceID = "0" }
        if let id = attr["Id"], let uuid = UUID(uuidString: id) { widget.id = uuid }
        widget.radius = int(attr["Radius"]) ?? 0

        let color = attr["Color"] ?? ""
        if color.count == 6 {
            widget.colorR = hexValue(color.prefix(2))
            widget.colorG = hexValue(color.dropFirst(2).prefix(2))
            widget.colorB = hexValue(color.dropFirst(4).prefix(2))
        }

        switch widget.kind {
        case .image:
            widget.bitmap = attr["Bitmap"] ?? ""
        case .imageList:
            widget.bitmapList = (attr["BitmapList"] ?? "")
                .split(separator: ",")
                .map(String.init)
            widget.indexSourceID = attr["Index_Src"] ?? "0"
            widget.defaultIndex = int(attr["DefaultIndex"]) ?? 0
        case .digitalNumber:
            widget.valueSourceID = attr["Value_Src"] ?? "8"
            widget.digits = int(attr["Digits"]) ?? 2
            widget.spacing = int(attr["Spacing"]) ?? 0
            widget.alignment = int(attr["Alignment"]) ?? 0
            widget.digitBackground = (attr["Digit_Background"] ?? "1") != "0"
        case .analog:
            widget.hourHandImage = attr["HourHand_ImageName"] ?? ""
            widget.minuteHandImage = attr["MinuteHand_ImageName"] ?? ""
            widget.secondHandImage = attr["SecondHand_ImageName"] ?? ""
            widget.background = attr["Background_ImageName"] ?? ""
            widget.foreground = attr["Foreground_ImageName"] ?? ""
            widget.rotateCenterX = int(attr["Rotate_xc"]) ?? 0
            widget.rotateCenterY = int(attr["Rotate_yc"]) ?? 0
        case .arc:
            widget.valueSourceID = attr["Value_Src"] ?? "8"
            widget.arcStartAngle = double(attr["StartAngle"]) ?? -90
            widget.arcEndAngle = double(attr["EndAngle"]) ?? 270
            widget.arcLineWidth = int(attr["Line_Width"]) ?? 8
            widget.rangeMin = int(attr["Range_Min"]) ?? 0
            widget.rangeMax = int(attr["Range_Max"]) ?? 100
        case .container:
            break
        case .pointer:
            widget.pointerImage = attr["Bitmap"] ?? ""
            widget.valueSourceID = attr["Value_Src"] ?? "8"
            let xc = int(attr["Rotate_xc"]) ?? 0
            let yc = int(attr["Rotate_yc"]) ?? 0
            if widget.width > 0 {
                widget.pointerAnchorX = Double(xc) / Double(widget.width)
                widget.pointerAnchorY = Double(yc) / Double(widget.height)
            }
        case .polyline:
            widget.lineWidth = int(attr["Line_Width"]) ?? 6
            widget.pointList = parsePoints(attr["Points"])
            widget.polylineFilled = (attr["Fill_Value"] ?? "0") == "1"
            if widget.polylineFilled {
                widget.valueSourceID = attr["Value_Src"] ?? "20"
                widget.rangeMin = int(attr["Range_Min"]) ?? 0
                widget.rangeMax = int(attr["Range_Max"]) ?? 100
            }
            widget.polylineFillDirection = int(attr["Fill_Direction"]) ?? 0
            widget.rotation = double(attr["Rotation"]) ?? 0
        }
        return widget
    }

    private static func kind(forShape shape: Int, attributes attr: [String: String]) -> WidgetKind {
        switch shape {
        case 30: return .image
        case 31: return .imageList
        case 32: return .digitalNumber
        case 42: return .arc
        case 34: return .container
        case 33: return .polyline
        case 27:
            // Shape 27 is shared: analog has hand image attributes, pointer does not.
            if (attr["HourHand_ImageName"] ?? "").isEmpty,
               (attr["MinuteHand_ImageName"] ?? "").isEmpty,
               (attr["SecondHand_ImageName"] ?? "").isEmpty {
                return .pointer
            }
            return .analog
        default: return .image
        }
    }

    private static func parsePoints(_ raw: String?) -> [CGPoint] {
        guard let raw else { return [] }
        var points: [CGPoint] = []
        for token in raw.split(separator: " ") {
            let parts = token.split(separator: ",")
            guard parts.count == 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]) else { continue }
            points.append(CGPoint(x: x / 100, y: y / 100))
        }
        return points
    }

    private static func int(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value)
    }

    private static func double(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value)
    }

    private static func hexValue(_ substring: Substring) -> Int {
        Int(substring, radix: 16) ?? 255
    }
}
