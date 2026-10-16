import CoreGraphics
import ImageIO
import XCTest
@testable import Mirante

final class O66Tests: XCTestCase {
    // MARK: - RLE

    func testRLEV1RoundTrip() throws {
        // Interleave runs and literals at 4 bytes-per-pixel (BGRA).
        var data: [UInt8] = []
        for _ in 0..<50 { data += [200, 100, 50, 255] }        // repeat run
        for value in 0..<40 { data += [UInt8(value), 0, 0, 255] }     // literals
        for _ in 0..<30 { data += [1, 2, 3, 4] }               // another run

        let encoded = try O66Rle.encodeV1(data, bytesPerPixel: 4)
        let decoded = try O66Rle.decodeV1(encoded, expectedLength: data.count, bytesPerPixel: 4)
        XCTAssertEqual(decoded, data)
    }

    func testRLEV2RoundTrip() throws {
        // Palette indices: runs of a single value plus literals.
        var data: [UInt8] = []
        for _ in 0..<40 { data.append(7) }
        for value in 0..<30 { data.append(UInt8(value)) }
        for _ in 0..<20 { data.append(3) }

        let encoded = O66Rle.encodeV2(data)
        let decoded = try O66Rle.decodeV2(encoded, expectedLength: data.count)
        XCTAssertEqual(decoded, data)
    }

    // MARK: - Codec

    func testPaletteCompressRoundTrip() throws {
        // A small image with few colors must take the palette path and decode
        // back to identical (opaque) pixels.
        let width = 12
        let height = 10
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                rgba[offset] = x >= width / 2 ? 220 : 20
                rgba[offset + 1] = y >= height / 2 ? 180 : 60
                rgba[offset + 2] = x * y % 2 == 0 ? 90 : 200
                rgba[offset + 3] = 255
            }
        }
        let image = O66RgbaImage(rgba: rgba, width: width, height: height)

        let encoded = try O66ImageCodec.encodeRgbaBlock(image, compress: true)
        XCTAssertTrue(encoded.compressed)
        let decoded = try O66ImageCodec.decodeImageBlock(encoded.block, offset: 0)
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(Array(decoded.rgba), rgba)
    }

    func testIndexedCompressRoundTrip() throws {
        // A translucent set of colors must round-trip through the BGRA path.
        let width = 8
        let height = 8
        let rgba = (0..<(width * height)).flatMap { pixel -> [UInt8] in
            [UInt8(pixel % 4 * 60), UInt8(pixel % 3 * 80), 40, UInt8(200 - pixel)]
        }
        let image = O66RgbaImage(rgba: rgba, width: width, height: height)
        let encoded = try O66ImageCodec.encodeRgbaBlock(image, compress: true)
        let decoded = try O66ImageCodec.decodeImageBlock(encoded.block, offset: 0)
        XCTAssertEqual(Array(decoded.rgba), rgba)
    }

    func testListRoundtrip() throws {
        var frames: [O66RgbaImage] = []
        for frame in 0..<3 {
            var rgba = [UInt8](repeating: 0, count: 4 * 4 * 4)
            for index in 0..<rgba.count {
                rgba[index] = UInt8(frame * 60 + index)
            }
            frames.append(O66RgbaImage(rgba: rgba, width: 4, height: 4))
        }
        let encoded = try O66ImageCodec.encodeImageList(frames, compress: true)
        let decoded = try O66ImageCodec.decodeImageListBlock(encoded.block, offset: 0)
        XCTAssertEqual(decoded.count, 3)
        for (frame, image) in frames.enumerated() {
            XCTAssertEqual(Array(decoded[frame].rgba), image.rgba)
            XCTAssertEqual(decoded[frame].width, image.width)
            XCTAssertEqual(decoded[frame].height, image.height)
        }
    }

    func testFingerprintDeduplicatesIdenticalPixels() {
        let a = O66RgbaImage(rgba: [1, 2, 3, 4, 5, 6, 7, 8], width: 1, height: 2)
        let b = O66RgbaImage(rgba: [1, 2, 3, 4, 5, 6, 7, 8], width: 1, height: 2)
        let c = O66RgbaImage(rgba: [1, 2, 3, 4, 5, 6, 7, 9], width: 1, height: 2)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.fingerprint, c.fingerprint)
    }

    // MARK: - Glyphs

    func testDigitFrames() throws {
        var widget = WidgetItem(kind: .digitalNumber, name: "Time")
        widget.digits = 4
        widget.spacing = 3
        widget.valueSourceID = "8"
        let frames = O66Glyphs.digitFrames(for: widget)
        XCTAssertEqual(frames.count, 11)
        XCTAssertTrue(frames.allSatisfy { $0.width > 0 && $0.height > 0 })
    }

    func testDigitOneIsUprightInTopFirstPixelBuffer() {
        var widget = WidgetItem(kind: .digitalNumber, name: "Time", width: 112, height: 107)
        widget.digits = 2
        let one = O66Glyphs.digitFrames(for: widget)[1]

        // The rounded 1 has a leftward hook at its top. Compare the occupied
        // x range in the upper and lower thirds of the glyph's actual pixels.
        let occupiedRows = (0..<one.height).filter { y in
            (0..<one.width).contains { x in one.rgba[(y * one.width + x) * 4 + 3] > 127 }
        }
        XCTAssertFalse(occupiedRows.isEmpty)
        guard let first = occupiedRows.first, let last = occupiedRows.last else { return }
        let upperEnd = first + (last - first) / 3
        let lowerStart = last - (last - first) / 3
        func leftmostPixel(in rows: ClosedRange<Int>) -> Int? {
            (0..<one.width).first { x in
                rows.contains(where: { y in one.rgba[(y * one.width + x) * 4 + 3] > 127 })
            }
        }
        guard let topLeft = leftmostPixel(in: first...upperEnd),
              let bottomLeft = leftmostPixel(in: lowerStart...last) else {
            XCTFail("Digit 1 is missing pixels in its upper or lower third")
            return
        }
        XCTAssertLessThan(topLeft, bottomLeft, "The hook of digit 1 must be at the top of the RGBA buffer")
    }

    func testAsymmetricDigitFramesSurviveWatchfaceImageListEncoding() throws {
        var widget = WidgetItem(kind: .digitalNumber, name: "Time", width: 112, height: 107)
        widget.digits = 2
        let frames = O66Glyphs.digitFrames(for: widget)
        let keys = frames.indices.map { "digit-\($0)" }
        let source = O66Compiler.SourceElement(
            kind: .number, x: 0, y: 0, listKeys: keys, dataSrc: "081102", showCount: 2
        )
        let images = Dictionary(uniqueKeysWithValues: zip(keys, frames))
        let prepared = try O66Compiler.prepare(elements: [source], images: images, compress: true)
        let decoded = try O66ImageCodec.decodeImageListBlock(prepared.lists[0].block, offset: 0)
        XCTAssertEqual(decoded.count, O66Glyphs.frameCount)
        // 1 and 2 are asymmetric under vertical inversion; the real image-list
        // encoder/decoder must preserve the corrected glyph pixels byte-for-byte.
        XCTAssertEqual(decoded[1].rgba, frames[1].rgba)
        XCTAssertEqual(decoded[2].rgba, frames[2].rgba)
    }

    // MARK: - Compilation

    func testCompileWithImageAndNumber() throws {
        var project = WatchFaceProject(name: "Smoke", deviceID: "xiaomi_band_10_pro")

        var image = WidgetItem(kind: .image, name: "Logo", x: 10, y: 20, width: 60, height: 40)
        image.alpha = 255
        let imageID = image.id
        project.widgets.append(image)
        project.images[imageID.uuidString] = makePNG(width: 60, height: 40)

        var number = WidgetItem(kind: .digitalNumber, name: "Time", x: 100, y: 150, width: 60, height: 30)
        number.digits = 4
        number.spacing = 4
        number.valueSourceID = "8"
        number.digitBackground = true
        project.widgets.append(number)

        let result = try FaceBinCompiler.compile(project)
        XCTAssertEqual(result.warnings, [])
        XCTAssertTrue(CompiledFaceMagic.matches(result.data))
        try O66Compiler.assertStructuralIntegrity([UInt8](result.data))
    }

    func testArcCompilesAsProgressWidget() throws {
        var project = WatchFaceProject(name: "Skipper", deviceID: "xiaomi_band_10_pro")
        var arc = WidgetItem(kind: .arc, name: "Steps", x: 0, y: 0, width: 100, height: 100)
        arc.valueSourceID = "9"
        project.widgets.append(arc)

        let result = try FaceBinCompiler.compile(project)
        XCTAssertEqual(result.warnings, [])
        try O66Compiler.assertStructuralIntegrity([UInt8](result.data))

        let source = O66Compiler.SourceElement(kind: .progress, x: 0, y: 0, imageKey: "arc", dataSrc: "0811")
        let prepared = O66Compiler.PreparedWidget(source: source, type: .progress, listIndex: nil, singleIndex: 2)
        let property = try O66Compiler.makeWidgetProperty(prepared)
        XCTAssertEqual(property[3], 0x40, "O66 identifies a progress widget with class 0x40")
        XCTAssertEqual(Array(property[8...11]), [2, 0, 0, 2], "Arc progress must reference its foreground image")
    }

    func testDigitalNumberElementPositionUsesAlignmentAnchor() throws {
        var warnings: [String] = []
        for (alignment, expectedX) in [(0, 40), (1, 90), (2, 140)] {
            var number = WidgetItem(kind: .digitalNumber, name: "Value", x: 40, y: 20, width: 100, height: 40)
            number.alignment = alignment
            let project = WatchFaceProject(name: "Anchor", deviceID: "band10pro", widgets: [number])
            let (elements, _) = try O66Compiler.sourceElements(from: project, warnings: &warnings)
            let numberElement = try XCTUnwrap(elements.first { $0.kind == .number })
            XCTAssertEqual(numberElement.x, expectedX, "alignment=\(alignment)")
        }
    }

    func testImageListCompilesAllFrames() throws {
        var project = WatchFaceProject(name: "Frames", deviceID: "xiaomi_band_10_pro")
        var list = WidgetItem(kind: .imageList, name: "Frames", x: 0, y: 0, width: 40, height: 40)
        list.bitmapList = ["one.png", "two.png"]
        project.widgets.append(list)
        project.images["\(list.id.uuidString)#0"] = makePNG(width: 40, height: 40)
        project.images["\(list.id.uuidString)#1"] = makePNG(width: 40, height: 40)

        let result = try FaceBinCompiler.compile(project)
        XCTAssertEqual(result.warnings, [])
        try O66Compiler.assertStructuralIntegrity([UInt8](result.data))
    }

    func testPolylineCompilesAsRasterElement() throws {
        var project = WatchFaceProject(name: "Line", deviceID: "xiaomi_band_10_pro")
        var line = WidgetItem(kind: .polyline, name: "Battery line", x: 0, y: 0, width: 80, height: 40)
        line.pointList = [CGPoint(x: 0, y: 1), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 1)]
        line.lineWidth = 4
        project.widgets.append(line)

        let result = try FaceBinCompiler.compile(project)
        XCTAssertEqual(result.warnings, [])
        try O66Compiler.assertStructuralIntegrity([UInt8](result.data))
    }

    func testPointerCompilesFromConfiguredBitmap() throws {
        var project = WatchFaceProject(name: "Pointer", deviceID: "xiaomi_band_10_pro")
        var pointer = WidgetItem(kind: .pointer, name: "Needle", x: 20, y: 20, width: 32, height: 32)
        pointer.pointerImage = "needle.png"
        project.widgets.append(pointer)
        project.images["needle.png"] = makePNG(width: 32, height: 32)

        let result = try FaceBinCompiler.compile(project)
        XCTAssertEqual(result.warnings, [])
        try O66Compiler.assertStructuralIntegrity([UInt8](result.data))
    }

    func testAnalogCompilesNamedAssetsAsStaticComposition() throws {
        var project = WatchFaceProject(name: "Analog", deviceID: "xiaomi_band_10_pro")
        var analog = WidgetItem(kind: .analog, name: "Clock", x: 0, y: 0, width: 48, height: 48)
        analog.background = "dial.png"
        analog.hourHandImage = "hour.png"
        analog.minuteHandImage = "minute.png"
        project.widgets.append(analog)
        project.images["dial.png"] = makePNG(width: 48, height: 48)
        project.images["hour.png"] = makePNG(width: 48, height: 48)
        project.images["minute.png"] = makePNG(width: 48, height: 48)

        let result = try FaceBinCompiler.compile(project)
        XCTAssertEqual(result.warnings, [])
        try O66Compiler.assertStructuralIntegrity([UInt8](result.data))
    }

    func testCompressionOptionChangesBinaryResources() throws {
        var project = WatchFaceProject(name: "Compression", deviceID: "xiaomi_band_10_pro")
        let image = WidgetItem(kind: .image, name: "Flat", x: 0, y: 0, width: 96, height: 96)
        project.widgets = [image]
        project.images[image.id.uuidString] = makePNG(width: 96, height: 96)

        let compressed = try FaceBinCompiler.compile(project, previewPNG: nil, compressImages: true)
        let raw = try FaceBinCompiler.compile(project, previewPNG: nil, compressImages: false)
        XCTAssertNotEqual(compressed.data, raw.data)
        XCTAssertLessThan(compressed.data.count, raw.data.count)
    }

    func testContainerActsAsStructuralGrouping() throws {
        var project = WatchFaceProject(name: "Container", deviceID: "xiaomi_band_10_pro")
        project.widgets = [WidgetItem(kind: .container, name: "Group")]
        let result = try FaceBinCompiler.compile(project)
        XCTAssertEqual(result.warnings, [])
        try O66Compiler.assertStructuralIntegrity([UInt8](result.data))
    }

    // MARK: - Helpers

    private func makePNG(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.25, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, kUTTypePNG, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
