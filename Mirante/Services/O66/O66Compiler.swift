import CryptoKit
import Foundation

/// The compiled o66 watchface produced by `O66Compiler`.
struct O66CompiledFace {
    let data: Data
    let warnings: [String]
}

/// Byte-for-byte port of the toolkit's `builder/native.ts`: assembles a valid
/// o66 `.bin` watchface — 0xA8 main header + 0x58 face header, definitions,
/// element/property tables, a compressed preview and the single/list resources.
enum O66Compiler {
    static let mainHeaderSize = 0xA8
    static let faceHeaderSize = 0x58
    static let definitionSize = 16
    static let namedFaceBlockSize = 0x48

    static let magic: [UInt8] = [0x5a, 0xa5, 0x34, 0x12]

    // MARK: - Sources

    enum SourceKind {
        case element
        case animation
        case number
        case progress
    }

    struct SourceElement {
        var kind: SourceKind
        var x: Int
        var y: Int
        var imageKey: String?          // single image (element)
        var listKeys: [String] = []    // image-list frames
        var dataSrc: String?           // hex data source ("0811", "1011", …)
        var showCount: Int?
        var showZero: Bool?
        var align: Int?
        var spacing: Int?
        var animIntervalMs: Int?
        var animRepeat: Int?
    }

    struct PreparedElement {
        let source: SourceElement
        let referenceType: Int
        let referenceIndex: Int
    }

    enum WidgetPropertyType {
        case number
        case progress
    }

    struct PreparedWidget {
        let source: SourceElement
        let type: WidgetPropertyType
        let listIndex: Int?
        let singleIndex: Int?
    }

    struct PreparedAnimation {
        let listIndex: Int
        let intervalMs: Int
        let repeatCount: Int
    }

    struct BinaryResource {
        let key: String
        let index: Int
        let block: [UInt8]
    }

    struct PreparedFace {
        let elements: [PreparedElement]
        let singles: [BinaryResource]
        let lists: [BinaryResource]
        let animations: [PreparedAnimation]
        let widgets: [PreparedWidget]
        let definitionSize: Int
        let propertySize: Int
    }

    // MARK: - Data sources

    /// Maps the app's fprj source ids (DataSourceCatalog) to the o66 data
    /// sources defined by the toolkit's `core/dataSources.ts`. Sources without
    /// a mapping ("0" none, "19" charging status) are dropped with a warning.
    static let dataSourceMap: [String: String] = [
        "8": "0811", "9": "1011", "10": "1811", "11": "1812", "12": "2012",
        "13": "1012", "14": "0812", "15": "2031", "20": "0841", "21": "0822",
        "23": "0821", "24": "1021", "25": "0823", "26": "1023", "27": "0824",
    ]

    static func resolvedDataSource(for fprjID: String, widgetName: String, warnings: inout [String]) -> String? {
        guard let hex = dataSourceMap[fprjID] else {
            warnings.append("“\(widgetName)”: data source \(fprjID) is not supported by the o66 compiler yet and was skipped.")
            return nil
        }
        return hex
    }

    // MARK: - Element building

    /// Builds the ordered element list from the project's widgets, mirroring
    /// what the live preview shows: single-image elements and digital-number
    /// widgets (with their optional rounded background). Unsupported kinds are
    /// skipped with a warning; hidden widgets are omitted silently.
    static func sourceElements(from project: WatchFaceProject, warnings: inout [String]) throws -> ([SourceElement], [String: O66RgbaImage]) {
        var elements: [SourceElement] = []
        var images: [String: O66RgbaImage] = [:]
        func store(_ image: O66RgbaImage) -> String {
            let key = image.fingerprint
            images[key] = image
            return key
        }
        for widget in project.widgets {
            guard widget.visible else { continue }
            switch widget.kind {
            case .image:
                guard let data = project.imageData(for: widget.id) else {
                    throw O66CompilerError.missingImage(widget.name)
                }
                let image = try O66ImageCodec.processed(
                    data,
                    width: max(1, widget.width),
                    height: max(1, widget.height),
                    radius: widget.radius,
                    alpha: widget.alpha
                )
                elements.append(SourceElement(
                    kind: .element,
                    x: widget.x,
                    y: widget.y,
                    imageKey: store(image)
                ))

            case .digitalNumber:
                guard let hex = resolvedDataSource(for: widget.valueSourceID, widgetName: widget.name, warnings: &warnings) else {
                    continue
                }
                if widget.digitBackground {
                    let background = O66Glyphs.digitBackgroundImage(for: widget)
                    elements.append(SourceElement(
                        kind: .element,
                        x: widget.x,
                        y: widget.y,
                        imageKey: store(background)
                    ))
                }
                let frames = O66Glyphs.digitFrames(for: widget)
                elements.append(SourceElement(
                    kind: .number,
                    x: widget.x,
                    y: widget.y,
                    listKeys: frames.map { store($0) },
                    dataSrc: hex,
                    showCount: max(1, widget.digits),
                    showZero: widget.valueSourceID == "8" || widget.valueSourceID == "9" || widget.valueSourceID == "10" || widget.valueSourceID == "11" || widget.valueSourceID == "13",
                    align: widget.alignment & 3,
                    spacing: widget.spacing
                ))

            case .imageList:
                warnings.append("“\(widget.name)”: image-list widgets are not supported by the o66 compiler yet and were skipped.")
            case .analog:
                warnings.append("“\(widget.name)”: analog displays are not supported by the o66 compiler yet and were skipped.")
            case .arc:
                warnings.append("“\(widget.name)”: arc progress widgets are not supported by the o66 compiler yet and were skipped.")
            case .container:
                warnings.append("“\(widget.name)”: container widgets are not supported by the o66 compiler yet and were skipped.")
            case .pointer:
                warnings.append("“\(widget.name)”: pointer widgets are not supported by the o66 compiler yet and were skipped.")
            case .polyline:
                warnings.append("“\(widget.name)”: polyline widgets are not supported by the o66 compiler yet and were skipped.")
            }
        }
        return (elements, images)
    }

    // MARK: - Preparation

    /// Port of `prepareFace`: deduplicates singles and lists by content, encodes
    /// every resource and produces the tables that drive the file layout.
    static func prepare(elements: [SourceElement], images: [String: O66RgbaImage], compress: Bool) throws -> PreparedFace {
        var singleNames: [String] = []
        var singleIndex: [String: Int] = [:]
        var listNames: [[String]] = []
        var listIndex: [String: Int] = [:]
        var preparedElements: [PreparedElement] = []
        var animations: [PreparedAnimation] = []
        var widgets: [PreparedWidget] = []

        func useSingle(_ key: String) -> Int {
            if let index = singleIndex[key] { return index }
            let index = singleNames.count
            singleNames.append(key)
            singleIndex[key] = index
            return index
        }

        func useList(_ keys: [String]) -> Int {
            let key = keys.joined(separator: "\u{1f}")
            if let index = listIndex[key] { return index }
            let index = listNames.count
            listNames.append(keys)
            listIndex[key] = index
            return index
        }

        for element in elements {
            switch element.kind {
            case .element:
                guard let image = element.imageKey else {
                    throw O66CompilerError.structural("Static element is missing its image")
                }
                preparedElements.append(PreparedElement(source: element, referenceType: 2, referenceIndex: useSingle(image)))
            case .animation:
                guard !element.listKeys.isEmpty else {
                    throw O66CompilerError.structural("Animation is missing frames")
                }
                let index = animations.count
                animations.append(PreparedAnimation(
                    listIndex: useList(element.listKeys),
                    intervalMs: element.animIntervalMs ?? 72,
                    repeatCount: element.animRepeat ?? 0
                ))
                preparedElements.append(PreparedElement(source: element, referenceType: 4, referenceIndex: index))
            case .number, .progress:
                let widgetIndex = widgets.count
                if element.kind == .number {
                    guard !element.listKeys.isEmpty else {
                        throw O66CompilerError.structural("Digital number is missing its digit images")
                    }
                    widgets.append(PreparedWidget(
                        source: element,
                        type: .number,
                        listIndex: useList(element.listKeys),
                        singleIndex: element.imageKey.map { useSingle($0) }
                    ))
                } else {
                    guard let image = element.imageKey else {
                        throw O66CompilerError.structural("Progress widget is missing its foreground image")
                    }
                    widgets.append(PreparedWidget(
                        source: element,
                        type: .progress,
                        listIndex: nil,
                        singleIndex: useSingle(image)
                    ))
                }
                preparedElements.append(PreparedElement(source: element, referenceType: 7, referenceIndex: widgetIndex))
            }
        }

        let singles = try singleNames.map { name -> BinaryResource in
            guard let image = images[name] else {
                throw O66CompilerError.missingImage(name)
            }
            return BinaryResource(
                key: name,
                index: singleIndex[name] ?? 0,
                block: try O66ImageCodec.encodeRgbaBlock(image, compress: compress).block
            )
        }
        let lists = try listNames.map { names -> BinaryResource in
            let frames = try names.map { name -> O66RgbaImage in
                guard let image = images[name] else {
                    throw O66CompilerError.missingImage(name)
                }
                return image
            }
            return BinaryResource(
                key: names.joined(separator: "\u{1f}"),
                index: listIndex[names.joined(separator: "\u{1f}")] ?? 0,
                block: try O66ImageCodec.encodeImageList(frames, compress: compress).block
            )
        }

        let definitionCount = preparedElements.count + singles.count + lists.count + animations.count + widgets.count
        let propertySize = preparedElements.count * 16
            + animations.count * 12
            + widgets.reduce(0) { $0 + widgetPropertySize($1) }
        return PreparedFace(
            elements: preparedElements,
            singles: singles,
            lists: lists,
            animations: animations,
            widgets: widgets,
            definitionSize: definitionCount * definitionSize,
            propertySize: propertySize
        )
    }

    static func widgetPropertySize(_ widget: PreparedWidget) -> Int {
        switch widget.type {
        case .number:
            return 20
        case .progress:
            return 40
        }
    }

    // MARK: - Property tables

    private static func writeDataSource(_ buffer: inout [UInt8], offset: Int, source: String?) throws {
        guard let source, !source.isEmpty else { return }
        var normalized = source.filter(\.isHexDigit)
        if normalized.count > 6 {
            throw O66CompilerError.structural("Native compiler does not yet support data source \(source) (>3 bytes)")
        }
        if !normalized.isEmpty && normalized.count % 2 == 1 {
            normalized = "0" + normalized
        }
        var bytes: [UInt8] = []
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(after: index)
            if let value = UInt8(String(normalized[index...next]), radix: 16) {
                bytes.append(value)
            }
            index = normalized.index(after: next)
        }
        if bytes.count > 3 {
            throw O66CompilerError.structural("Native compiler does not yet support data source \(source) (>3 bytes)")
        }
        buffer.replaceSubrange(offset..<(offset + min(3, bytes.count)), with: bytes.prefix(3))
    }

    static func makeWidgetProperty(_ widget: PreparedWidget) throws -> [UInt8] {
        let source = widget.source
        var property = [UInt8](repeating: 0, count: widgetPropertySize(widget))
        try writeDataSource(&property, offset: 0, source: source.dataSrc)

        switch widget.type {
        case .number:
            property[2] = UInt8(max(1, source.showCount ?? 1))
            property[3] = 0x10 | ((source.showZero ?? false ? 1 : 0) << 2) | UInt8((source.align ?? 1) & 0x03)
            O66Bytes.writeU24LE(&property, 8, widget.listIndex ?? 0)
            property[11] = 3
            property[13] = UInt8((source.spacing ?? 0) & 0xff)
            if let singleIndex = widget.singleIndex {
                O66Bytes.writeU24LE(&property, 16, singleIndex)
                property[19] = 2
            }
        case .progress:
            property[3] = 0x40
            O66Bytes.writeU24LE(&property, 8, widget.singleIndex ?? 0)
            property[11] = 2
        }
        return property
    }

    // MARK: - Header + face data

    private static func writeSection(_ header: inout [UInt8], _ offset: Int, count: Int, tableOffset: Int) {
        O66Bytes.writeU32LE(&header, offset, count)
        O66Bytes.writeU32LE(&header, offset + 4, tableOffset)
    }

    static func makeFaceHeader(face: PreparedFace, definitionStart: Int, previewOffset: Int) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: faceHeaderSize)
        O66Bytes.writeU32LE(&header, 4, previewOffset)
        var offset = definitionStart
        writeSection(&header, 0x08, count: face.elements.count, tableOffset: offset)
        offset += face.elements.count * definitionSize
        writeSection(&header, 0x10, count: 0, tableOffset: offset)
        writeSection(&header, 0x18, count: face.singles.count, tableOffset: offset)
        offset += face.singles.count * definitionSize
        writeSection(&header, 0x20, count: face.lists.count, tableOffset: offset)
        offset += face.lists.count * definitionSize
        writeSection(&header, 0x28, count: face.animations.count, tableOffset: offset)
        offset += face.animations.count * definitionSize
        writeSection(&header, 0x30, count: 0, tableOffset: offset)
        writeSection(&header, 0x38, count: 0, tableOffset: offset)
        writeSection(&header, 0x40, count: face.widgets.count, tableOffset: offset)
        offset += face.widgets.count * definitionSize
        writeSection(&header, 0x48, count: 0, tableOffset: offset)
        writeSection(&header, 0x50, count: 0, tableOffset: offset)
        return header
    }

    private static func writeDefinition(
        _ buffer: inout [UInt8],
        _ offset: Int,
        index: Int,
        type: Int,
        target: Int,
        length: Int
    ) {
        O66Bytes.writeU16LE(&buffer, offset, index)
        buffer[offset + 3] = UInt8(type)
        O66Bytes.writeU32LE(&buffer, offset + 8, target)
        O66Bytes.writeU32LE(&buffer, offset + 12, length)
    }

    private static func faceResources(_ face: PreparedFace) -> [BinaryResource] {
        face.singles + face.lists
    }

    private static func resourceOffsets(_ face: PreparedFace, start: Int) -> (singles: [Int], lists: [Int]) {
        var singles: [Int] = []
        var lists: [Int] = []
        var offset = start
        for resource in face.singles {
            singles.append(offset)
            offset += resource.block.count
        }
        for resource in face.lists {
            lists.append(offset)
            offset += resource.block.count
        }
        return (singles, lists)
    }

    static func makeFaceData(
        face: PreparedFace,
        propertyStart: Int,
        resources: (singles: [Int], lists: [Int])
    ) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: face.definitionSize + face.propertySize)
        var definitionOffset = 0
        var propertyOffset = face.definitionSize
        var absolutePropertyOffset = propertyStart

        for index in 0..<face.elements.count {
            writeDefinition(&output, definitionOffset, index: index, type: 0, target: absolutePropertyOffset, length: 16)
            definitionOffset += definitionSize
            absolutePropertyOffset += 16
        }
        for resource in face.singles {
            writeDefinition(&output, definitionOffset, index: resource.index, type: 2, target: resources.singles[resource.index], length: resource.block.count)
            definitionOffset += definitionSize
        }
        for resource in face.lists {
            writeDefinition(&output, definitionOffset, index: resource.index, type: 3, target: resources.lists[resource.index], length: resource.block.count)
            definitionOffset += definitionSize
        }
        for index in 0..<face.animations.count {
            writeDefinition(&output, definitionOffset, index: index, type: 4, target: absolutePropertyOffset, length: 12)
            definitionOffset += definitionSize
            absolutePropertyOffset += 12
        }
        for (index, widget) in face.widgets.enumerated() {
            let size = widgetPropertySize(widget)
            writeDefinition(&output, definitionOffset, index: index, type: 7, target: absolutePropertyOffset, length: size)
            definitionOffset += definitionSize
            absolutePropertyOffset += size
        }

        for element in face.elements {
            O66Bytes.writeU24LE(&output, propertyOffset, element.referenceIndex)
            output[propertyOffset + 3] = UInt8(element.referenceType)
            O66Bytes.writeU16LE(&output, propertyOffset + 4, element.source.x & 0xffff)
            O66Bytes.writeU16LE(&output, propertyOffset + 6, element.source.y & 0xffff)
            propertyOffset += 16
        }
        for animation in face.animations {
            O66Bytes.writeU24LE(&output, propertyOffset, animation.listIndex)
            output[propertyOffset + 3] = 3
            O66Bytes.writeU16LE(&output, propertyOffset + 6, animation.intervalMs)
            O66Bytes.writeU16LE(&output, propertyOffset + 8, animation.repeatCount)
            propertyOffset += 12
        }
        for widget in face.widgets {
            let property = try makeWidgetProperty(widget)
            output.replaceSubrange(propertyOffset..<(propertyOffset + property.count), with: property)
            propertyOffset += property.count
        }
        return output
    }

    // MARK: - Assembly

    static func makeMainHeader(id: String, name: String, faceCount: Int, previewOffset: Int) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: mainHeaderSize)
        header.replaceSubrange(0..<4, with: magic)
        O66Bytes.writeU32LE(&header, 0x10, 0x800)
        O66Bytes.writeU16LE(&header, 0x1c, faceCount)
        O66Bytes.writeU16LE(&header, 0x1e, faceCount > 1 ? faceCount + 2 : 1)
        O66Bytes.writeU32LE(&header, 0x20, previewOffset)
        O66Bytes.writeFixedString(&header, 0x28, 9, id)
        O66Bytes.writeFixedString(&header, 0x68, 60, name)
        return header
    }

    /// FNV-1a (32-bit) hashed to a fixed 9-digit package id, the identifier
    /// `XiaomiProto.watchfaceID` reads back from the main header.
    static func numericID(from name: String, deviceID: String) -> String {
        let seed = name.utf8.reduce(UInt32(2166136261)) { ($0 &* 16777619) ^ UInt32($1) }
        let combined = deviceID.utf8.reduce(seed) { ($0 &* 16777619) ^ UInt32($1) }
        return String(format: "%09d", Int(combined % 1_000_000_000))
    }

    /// Produces a placeholder preview (a dark rounded panel) when the caller
    /// couldn't render a real one, so the file always carries a preview block.
    static func placeholderPreview(width: Int, height: Int) -> O66RgbaImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let radius = min(8, width / 8, height / 8)
        let cornerR = CGFloat(max(1, radius))
        for y in 0..<height {
            for x in 0..<width {
                var distance: CGFloat = 0
                if x < radius && y < radius {
                    distance = hypot(CGFloat(x) - cornerR, CGFloat(y) - cornerR)
                } else if x >= width - radius && y < radius {
                    distance = hypot(CGFloat(x) - CGFloat(width - radius), CGFloat(y) - cornerR)
                } else if x < radius && y >= height - radius {
                    distance = hypot(CGFloat(x) - cornerR, CGFloat(y) - CGFloat(height - radius))
                } else if x >= width - radius && y >= height - radius {
                    distance = hypot(CGFloat(x) - CGFloat(width - radius), CGFloat(y) - CGFloat(height - radius))
                }
                let inside = distance <= cornerR
                switch x % 53 {
                case 0:
                    if inside {
                        let offset = (y * width + x) * 4
                        rgba[offset] = 32
                        rgba[offset + 1] = 38
                        rgba[offset + 2] = 48
                        rgba[offset + 3] = 255
                    }
                case 26:
                    if inside {
                        let offset = (y * width + x) * 4
                        rgba[offset] = 36
                        rgba[offset + 1] = 44
                        rgba[offset + 2] = 56
                        rgba[offset + 3] = 255
                    }
                default:
                    if inside {
                        let offset = (y * width + x) * 4
                        rgba[offset] = 24
                        rgba[offset + 1] = 30
                        rgba[offset + 2] = 40
                        rgba[offset + 3] = 255
                    }
                }
            }
        }
        return O66RgbaImage(rgba: rgba, width: width, height: height)
    }

    // MARK: - Compile

    /// Full o66 build. `previewPNG` is the rendered face preview at the
    /// device's preview size; pass nil to embed the placeholder instead.
    static func compile(project: WatchFaceProject, previewPNG: Data?) throws -> O66CompiledFace {
        var warnings: [String] = []
        let (elements, images) = try sourceElements(from: project, warnings: &warnings)
        let face = try prepare(elements: elements, images: images, compress: true)

        let id = numericID(from: project.name, deviceID: project.deviceID)
        guard id.count == 9, id.allSatisfy(\.isNumber) else {
            throw O66CompilerError.invalidID
        }
        guard project.name.utf8.count <= 60 else {
            throw O66CompilerError.invalidData("Face name is longer than the 60-byte header slot")
        }

        let preview: O66RgbaImage
        let device = project.device
        let previewWidth = Int(device.previewSize.width)
        let previewHeight = Int(device.previewSize.height)
        if let previewPNG {
            let decoded = try O66ImageCodec.rgba(from: previewPNG)
            preview = O66ImageCodec.fillScaled(decoded, width: previewWidth, height: previewHeight)
        } else {
            preview = placeholderPreview(width: previewWidth, height: previewHeight)
        }
        let previewBlock = try O66ImageCodec.encodeRgbaBlock(preview, compress: true).block

        let faceCount = 1
        let headersEnd = mainHeaderSize + faceCount * faceHeaderSize
        let normalDefinitionStart = headersEnd
        let normalPropertyStart = normalDefinitionStart + face.definitionSize
        let previewOffset = normalPropertyStart + face.propertySize
        let normalResourceStart = previewOffset + previewBlock.count
        let offsets = resourceOffsets(face, start: normalResourceStart)
        let normalData = try makeFaceData(face: face, propertyStart: normalPropertyStart, resources: offsets)

        var parts: [[UInt8]] = [
            makeMainHeader(id: id, name: project.name, faceCount: faceCount, previewOffset: previewOffset),
            makeFaceHeader(face: face, definitionStart: normalDefinitionStart, previewOffset: previewOffset),
            normalData,
            previewBlock,
        ]
        parts += faceResources(face).map(\.block)

        var binary: [UInt8] = []
        for part in parts {
            binary.append(contentsOf: part)
        }

        try assertStructuralIntegrity(binary)
        return O66CompiledFace(data: Data(binary), warnings: warnings)
    }

    // MARK: - Structural self-check

    /// Mirrors `binary.ts`'s section walking; throws on anything "outside the
    /// file" so a malformed build never reaches the band.
    static func assertStructuralIntegrity(_ buffer: [UInt8]) throws {
        guard buffer.count >= mainHeaderSize + faceHeaderSize else {
            throw O66CompilerError.structural("Watch-face header is outside the file (size \(buffer.count))")
        }
        guard Array(buffer[0..<4]) == magic else {
            throw O66CompilerError.structural("Missing o66 magic")
        }
        let faceCount = O66Bytes.readU16LE(buffer, 0x1c)
        let namedFaces = O66Compiler.isNamedFaces(in: buffer)
        let previewOffset = O66Bytes.readU32LE(buffer, 0x20)
        guard previewOffset < buffer.count else {
            throw O66CompilerError.structural("Preview is outside the file (offset \(previewOffset), size \(buffer.count))")
        }

        let sections: [(type: Int, position: Int)] = [(0, 0x08), (2, 0x18), (3, 0x20), (4, 0x28), (5, 0x30), (7, 0x40), (8, 0x48), (9, 0x50)]

        for faceIndex in 0..<faceCount {
            let faceOffset = mainHeaderSize + faceIndex * (faceHeaderSize + (namedFaces ? namedFaceBlockSize : 0))
            guard faceOffset + faceHeaderSize <= buffer.count else {
                throw O66CompilerError.structural("Face \(faceIndex) header is outside the file")
            }
            for (type, position) in sections {
                let count = O66Bytes.readU32LE(buffer, faceOffset + position)
                let tableOffset = O66Bytes.readU32LE(buffer, faceOffset + position + 4)
                guard count == 0 || tableOffset + Int(count) * definitionSize <= buffer.count else {
                    throw O66CompilerError.structural("Face \(faceIndex) section \(type) is outside the file (count \(count), table \(tableOffset))")
                }
                for definition in 0..<Int(count) {
                    let target = O66Bytes.readU32LE(buffer, tableOffset + definition * definitionSize + 8)
                    let length = O66Bytes.readU32LE(buffer, tableOffset + definition * definitionSize + 12)
                    guard target + Int(length) <= buffer.count else {
                        throw O66CompilerError.structural("Face \(faceIndex) definition \(type)/\(definition) is outside the file (offset \(target), length \(length), size \(buffer.count))")
                    }
                }
            }
        }
    }

    /// `binary.ts` detectNamedFaces: single-face files use the compact layout
    /// (false); would-be-named layouts are detected by the taller stride.
    static func isNamedFaces(in buffer: [UInt8]) -> Bool {
        guard buffer.count >= mainHeaderSize + 0x0c + 4 else { return false }
        let faceCount = O66Bytes.readU16LE(buffer, 0x1c)
        let firstDefinitionOffset = O66Bytes.readU32LE(buffer, mainHeaderSize + 0x0c)
        let legacyHeadersEnd = mainHeaderSize + Int(faceCount) * faceHeaderSize
        let namedHeadersEnd = mainHeaderSize + Int(faceCount) * (faceHeaderSize + namedFaceBlockSize)
        return firstDefinitionOffset >= namedHeadersEnd && firstDefinitionOffset > legacyHeadersEnd
    }
}