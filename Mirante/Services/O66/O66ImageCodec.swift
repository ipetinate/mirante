import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A straight-alpha RGBA bitmap (one byte per channel, top row first).
/// Mirrors the toolkit's `sharp(...).raw()` output that feeds the encoder.
struct O66RgbaImage {
    var rgba: [UInt8]
    let width: Int
    let height: Int

    var rgbaData: Data { Data(rgba) }

    /// A content fingerprint used to deduplicate identical images. Two images
    /// that differ in neither pixels nor size share a key.
    var fingerprint: String {
        var hasher = SHA256()
        var dims = [UInt8](repeating: 0, count: 8)
        dims[0] = UInt8(width & 0xff)
        dims[1] = UInt8((width >> 8) & 0xff)
        dims[2] = UInt8((width >> 16) & 0xff)
        dims[3] = UInt8((width >> 24) & 0xff)
        dims[4] = UInt8(height & 0xff)
        dims[5] = UInt8((height >> 8) & 0xff)
        dims[6] = UInt8((height >> 16) & 0xff)
        dims[7] = UInt8((height >> 24) & 0xff)
        hasher.update(data: Data(dims))
        hasher.update(data: rgbaData)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// PGK / PNG8 "e0 21 a5 5a" compressed image codec used by the mi8pro watchface
/// family, ported byte-for-byte from the toolkit's `parser/imageCodec.ts`.
enum O66ImageCodec {
    static let compressedImageMagic: [UInt8] = [0xe0, 0x21, 0xa5, 0x5a]
    static let imageHeaderSize = 12
    static let paletteBytes = 256 * 4

    struct EncodedImage {
        var block: [UInt8]
        let width: Int
        let height: Int
        let sign: Int
        let compressed: Bool
        let colors: Int
    }

    struct DecodedImage {
        var rgba: [UInt8]
        let width: Int
        let height: Int
        let sign: Int
        let encodedLength: Int
        let compressed: Bool
    }

    // MARK: - PNG decoding

    /// Decodes any image file (PNG, JPEG, TIFF, HEIC, …) into straight-alpha
    /// sRGB RGBA, top row first. This is the sharp `ensureAlpha().raw()`
    /// equivalent: it un-premultiplies and strips any colour profile.
    static func rgba(from data: Data) throws -> O66RgbaImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw O66CompilerError.invalidData("Could not decode image data (\(data.count) bytes)")
        }
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0, width * height < 1 << 24 else {
            throw O66CompilerError.invalidData("Unreasonable image dimensions \(width)×\(height)")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw O66CompilerError.invalidData("Could not allocate a \(width)×\(height) RGBA context")
        }
        context.interpolationQuality = .high
        // Flip so the buffer is top-row-first, matching ImageIO's memory order.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Un-premultiply: sharp's raw output is straight (non-premultiplied).
        var offset = 0
        while offset < pixels.count {
            let alpha = Int(pixels[offset + 3])
            if alpha > 0 && alpha < 255 {
                pixels[offset] = UInt8(min(255, (Int(pixels[offset]) * 255) / alpha))
                pixels[offset + 1] = UInt8(min(255, (Int(pixels[offset + 1]) * 255) / alpha))
                pixels[offset + 2] = UInt8(min(255, (Int(pixels[offset + 2]) * 255) / alpha))
            } else if alpha == 0 {
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
            }
            offset += 4
        }
        return O66RgbaImage(rgba: pixels, width: width, height: height)
    }

    /// Scales the image to `width`×`height` with a fill-scale center crop,
    /// matching the design canvas so the band sees the same framing as the app.
    static func fillScaled(_ image: O66RgbaImage, width: Int, height: Int) -> O66RgbaImage {
        guard width > 0, height > 0, width != image.width || height != image.height else { return image }
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let scaledWidth = Int(ceil(CGFloat(image.width) * scale))
        let scaledHeight = Int(ceil(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let sourceImage = makeCGImage(from: image)
        if let sourceImage {
            let dx = CGFloat(scaledWidth - width) / 2
            let dy = CGFloat(scaledHeight - height) / 2
            context.draw(sourceImage, in: CGRect(x: -dx, y: -dy, width: CGFloat(scaledWidth), height: CGFloat(scaledHeight)))
        }
        var output = O66RgbaImage(rgba: pixels, width: width, height: height)
        unpremultiply(&output)
        return output
    }

    /// Wraps a rounded-rect mask around the image's alpha channel. Pixels whose
    /// centre falls outside a rounded rectangle of `radius` become transparent.
    static func rounded(_ image: O66RgbaImage, radius: Int) -> O66RgbaImage {
        guard radius > 0 else { return image }
        let r = min(radius, image.width / 2, image.height / 2)
        var output = image
        let cornerR = CGFloat(max(1, r))
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                var distance: CGFloat = 0
                if x < r && y < r {
                    distance = hypot(CGFloat(x) - cornerR, CGFloat(y) - cornerR)
                } else if x >= image.width - r && y < r {
                    distance = hypot(CGFloat(x) - CGFloat(image.width - r), CGFloat(y) - cornerR)
                } else if x < r && y >= image.height - r {
                    distance = hypot(CGFloat(x) - cornerR, CGFloat(y) - CGFloat(image.height - r))
                } else if x >= image.width - r && y >= image.height - r {
                    distance = hypot(CGFloat(x) - CGFloat(image.width - r), CGFloat(y) - CGFloat(image.height - r))
                }
                if distance > cornerR {
                    output.rgba[offset + 3] = 0
                }
            }
        }
        return output
    }

    /// Bakes a global opacity (0–255, `widget.alpha`) into the alpha channel.
    static func applyingOpacity(_ image: O66RgbaImage, alpha: Int) -> O66RgbaImage {
        let factor = min(max(Double(alpha), 0), 255) / 255
        guard factor < 1 else { return image }
        var output = image
        var offset = 0
        while offset < output.rgba.count {
            output.rgba[offset + 3] = UInt8(round(Double(output.rgba[offset + 3]) * factor))
            offset += 4
        }
        return output
    }

    // MARK: - Raw conversion

    static func rgbaToBgra(_ rgba: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: rgba.count)
        var offset = 0
        while offset < rgba.count {
            output[offset] = rgba[offset + 2]
            output[offset + 1] = rgba[offset + 1]
            output[offset + 2] = rgba[offset]
            output[offset + 3] = rgba[offset + 3]
            offset += 4
        }
        return output
    }

    private static func colorKey(_ data: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(data[offset + 3]) << 24)
            | (UInt32(data[offset]) << 16)
            | (UInt32(data[offset + 1]) << 8)
            | UInt32(data[offset + 2])
    }

    /// Builds the 256-colour palette + pixel-index payload used by indexed
    /// images. Returns nil when the image has more than 256 unique colours.
    static func indexedPixels(_ rgba: [UInt8]) -> (data: [UInt8], colors: Int)? {
        var palette: [UInt32: Int] = [:]
        var indices = [UInt8](repeating: 0, count: rgba.count / 4)
        var offset = 0
        var pixel = 0
        while offset < rgba.count {
            let key = colorKey(rgba, offset)
            if let index = palette[key] {
                indices[pixel] = UInt8(index)
            } else {
                guard palette.count < 256 else { return nil }
                let index = palette.count
                palette[key] = index
                indices[pixel] = UInt8(index)
            }
            offset += 4
            pixel += 1
        }
        var output = [UInt8](repeating: 0, count: paletteBytes + indices.count)
        for (key, index) in palette {
            let offset = index * 4
            output[offset] = UInt8(key & 0xff)
            output[offset + 1] = UInt8((key >> 8) & 0xff)
            output[offset + 2] = UInt8((key >> 16) & 0xff)
            output[offset + 3] = UInt8((key >> 24) & 0xff)
        }
        output.replaceSubrange(paletteBytes..<(paletteBytes + indices.count), with: indices)
        return (output, palette.count)
    }

    // MARK: - Encoding

    static func compressedPayload(_ raw: [UInt8], bytesPerPixel: Int, palette: Bool) throws -> [UInt8] {
        let encoded = try palette ? O66Rle.encodeV2(raw) : O66Rle.encodeV1(raw, bytesPerPixel: bytesPerPixel)
        var payload = [UInt8](repeating: 0, count: 8 + encoded.count)
        payload.replaceSubrange(0..<4, with: compressedImageMagic)
        O66Bytes.writeU32LE(&payload, 4, (raw.count << 4) | bytesPerPixel)
        payload.replaceSubrange(8..<(8 + encoded.count), with: encoded)
        return payload
    }

    static func encodeRgbaBlock(_ rgba: [UInt8], width: Int, height: Int, compress: Bool, listCount: Int) throws -> EncodedImage {
        let indexed = indexedPixels(rgba)
        let sign = indexed == nil ? 0 : 0x10
        let bytesPerPixel = indexed == nil ? 4 : 1
        let raw = indexed?.data ?? rgbaToBgra(rgba)
        let payload = compress ? try compressedPayload(raw, bytesPerPixel: bytesPerPixel, palette: indexed != nil) : raw
        var header = [UInt8](repeating: 0, count: imageHeaderSize)
        header[0] = UInt8(sign)
        if listCount == 0 && compress {
            header[1] = 4
        }
        O66Bytes.writeU16LE(&header, 4, width)
        O66Bytes.writeU16LE(&header, 6, height)
        O66Bytes.writeU32LE(&header, 8, payload.count)
        let block = header + payload
        return EncodedImage(
            block: block,
            width: width,
            height: height,
            sign: sign,
            compressed: compress,
            colors: indexed?.colors ?? 257
        )
    }

    static func encodeRgbaBlock(_ image: O66RgbaImage, compress: Bool) throws -> EncodedImage {
        try encodeRgbaBlock(image.rgba, width: image.width, height: image.height, compress: compress, listCount: 0)
    }

    static func encodeImageList(_ frames: [O66RgbaImage], compress: Bool) throws -> EncodedImage {
        try encodeImageList(frames.map(\.rgba), sizes: frames.map { ($0.width, $0.height) }, compress: compress)
    }

    private static func encodeImageList(_ rgbaFrames: [[UInt8]], sizes: [(Int, Int)], compress: Bool) throws -> EncodedImage {
        guard !rgbaFrames.isEmpty, rgbaFrames.count <= 255 else {
            throw O66CompilerError.invalidData("Image lists must contain 1–255 images")
        }
        let firstWidth = sizes[0].0
        let firstHeight = sizes[0].1
        for (index, size) in sizes.enumerated() where size.0 != firstWidth || size.1 != firstHeight {
            throw O66CompilerError.invalidData("Image list item \(index) is \(size.0)×\(size.1); expected \(firstWidth)×\(firstHeight)")
        }
        let indexed = rgbaFrames.allSatisfy { indexedPixels($0) != nil }
        let sign = indexed ? 0x10 : 0
        var payloads: [[UInt8]] = []
        for rgba in rgbaFrames {
            let palette = indexed ? indexedPixels(rgba) : nil
            let raw = palette?.data ?? rgbaToBgra(rgba)
            payloads.append(compress ? try compressedPayload(raw, bytesPerPixel: indexed ? 1 : 4, palette: indexed) : raw)
        }
        let tableLength = compress ? payloads.count * 4 : 0
        let payloadLength = payloads.reduce(tableLength) { $0 + $1.count }
        var block = [UInt8](repeating: 0, count: imageHeaderSize + payloadLength)
        block[0] = UInt8(sign)
        block[1] = UInt8(rgbaFrames.count)
        if compress {
            block[2] = 4
        }
        O66Bytes.writeU16LE(&block, 4, firstWidth)
        O66Bytes.writeU16LE(&block, 6, firstHeight)
        O66Bytes.writeU32LE(&block, 8, payloadLength)
        var offset = imageHeaderSize + tableLength
        for (index, payload) in payloads.enumerated() {
            if compress {
                O66Bytes.writeU32LE(&block, imageHeaderSize + index * 4, payload.count)
            }
            block.replaceSubrange(offset..<(offset + payload.count), with: payload)
            offset += payload.count
        }
        let maxColors = rgbaFrames.compactMap { indexedPixels($0)?.colors }.max() ?? 0
        return EncodedImage(
            block: block,
            width: firstWidth,
            height: firstHeight,
            sign: sign,
            compressed: compress,
            colors: indexed ? maxColors : 257
        )
    }

    // MARK: - Decoding

    private static func hasCompressedMagic(_ buffer: [UInt8], _ offset: Int) -> Bool {
        guard offset + 4 <= buffer.count else { return false }
        for (index, value) in compressedImageMagic.enumerated() where buffer[offset + index] != value {
            return false
        }
        return true
    }

    private static func decodeRawPixels(_ raw: [UInt8], sign: Int, width: Int, height: Int, bytesPerPixel: Int) throws -> [UInt8] {
        let pixelCount = width * height
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)

        if sign == 0x10 || bytesPerPixel == 1 {
            guard raw.count >= paletteBytes + pixelCount else {
                throw O66CompilerError.invalidData("Indexed image payload is shorter than its palette and pixels")
            }
            for pixel in 0..<pixelCount {
                let paletteOffset = Int(raw[paletteBytes + pixel]) * 4
                let output = pixel * 4
                rgba[output] = raw[paletteOffset + 2]
                rgba[output + 1] = raw[paletteOffset + 1]
                rgba[output + 2] = raw[paletteOffset]
                rgba[output + 3] = raw[paletteOffset + 3]
            }
            return rgba
        }

        if bytesPerPixel == 4 {
            guard raw.count >= pixelCount * 4 else {
                throw O66CompilerError.invalidData("BGRA image payload is truncated")
            }
            for pixel in 0..<pixelCount {
                let input = pixel * 4
                let output = pixel * 4
                rgba[output] = raw[input + 2]
                rgba[output + 1] = raw[input + 1]
                rgba[output + 2] = raw[input]
                rgba[output + 3] = raw[input + 3]
            }
            return rgba
        }

        if bytesPerPixel == 3 || bytesPerPixel == 2 {
            for pixel in 0..<pixelCount {
                let input = pixel * bytesPerPixel
                let low = Int(raw[input])
                let high = Int(raw[input + 1])
                let output = pixel * 4
                rgba[output] = UInt8(high & 0xf8)
                rgba[output + 1] = UInt8((((high & 0x07) << 5) | ((low & 0xe0) >> 3)) & 0xfc)
                rgba[output + 2] = UInt8((low & 0x1f) << 3)
                rgba[output + 3] = bytesPerPixel == 3 ? raw[input + 2] : 255
            }
            return rgba
        }

        throw O66CompilerError.invalidData("Unsupported image bytes-per-pixel value \(bytesPerPixel)")
    }

    private static func decodePayload(
        _ buffer: [UInt8],
        offset: Int,
        length: Int,
        sign: Int,
        width: Int,
        height: Int
    ) throws -> (rgba: [UInt8], compressed: Bool) {
        guard offset >= 0, length >= 0, offset + length <= buffer.count else {
            throw O66CompilerError.invalidData("Image payload is outside the binary")
        }
        var raw: [UInt8]
        var bytesPerPixel: Int
        var compressed = false

        if length >= 8 && hasCompressedMagic(buffer, offset) {
            let info = O66Bytes.readU32LE(buffer, offset + 4)
            bytesPerPixel = info & 0x0f
            let expectedLength = info >> 4
            let encoded = Array(buffer[offset + 8..<(offset + length)])
            if sign == 0x10 || bytesPerPixel == 1 {
                raw = try O66Rle.decodeV2(encoded, expectedLength: expectedLength)
            } else {
                raw = try O66Rle.decodeV1(encoded, expectedLength: expectedLength, bytesPerPixel: bytesPerPixel)
            }
            compressed = true
        } else {
            raw = Array(buffer[offset..<(offset + length)])
            bytesPerPixel = sign == 6 ? 3 : sign == 3 ? 2 : sign == 0x10 ? 1 : 4
        }

        let rgba = try decodeRawPixels(raw, sign: sign, width: width, height: height, bytesPerPixel: bytesPerPixel)
        return (rgba, compressed)
    }

    static func decodeImageBlock(_ buffer: [UInt8], offset: Int) throws -> DecodedImage {
        guard offset >= 0, offset + imageHeaderSize <= buffer.count else {
            throw O66CompilerError.invalidData("Image header is outside the binary")
        }
        let sign = Int(buffer[offset])
        let width = O66Bytes.readU16LE(buffer, offset + 4)
        let height = O66Bytes.readU16LE(buffer, offset + 6)
        let encodedLength = O66Bytes.readU32LE(buffer, offset + 8)
        if width == 0 || height == 0 {
            throw O66CompilerError.invalidData("Invalid image dimensions \(width)×\(height) at offset \(offset)")
        }
        let decoded = try decodePayload(buffer, offset: offset + imageHeaderSize, length: encodedLength, sign: sign, width: width, height: height)
        return DecodedImage(
            rgba: decoded.rgba,
            width: width,
            height: height,
            sign: sign,
            encodedLength: imageHeaderSize + encodedLength,
            compressed: decoded.compressed
        )
    }

    static func decodeImageListBlock(_ buffer: [UInt8], offset: Int) throws -> [DecodedImage] {
        guard offset >= 0, offset + imageHeaderSize <= buffer.count else {
            throw O66CompilerError.invalidData("Image-list header is outside the binary")
        }
        let sign = Int(buffer[offset])
        let count = Int(buffer[offset + 1])
        let compressed = buffer[offset + 2] == 4 || buffer[offset + 2] == 8
        let width = O66Bytes.readU16LE(buffer, offset + 4)
        let height = O66Bytes.readU16LE(buffer, offset + 6)
        let totalLength = O66Bytes.readU32LE(buffer, offset + 8)
        if count == 0 || width == 0 || height == 0 {
            throw O66CompilerError.invalidData("Invalid image list at offset \(offset)")
        }
        guard offset + imageHeaderSize + totalLength <= buffer.count else {
            throw O66CompilerError.invalidData("Image-list payload is outside the binary")
        }
        let lengths: [Int]
        if compressed {
            lengths = (0..<count).map { index in O66Bytes.readU32LE(buffer, offset + imageHeaderSize + index * 4) }
        } else {
            let even = totalLength / count
            lengths = Array(repeating: even, count: count)
        }
        var payloadOffset = offset + imageHeaderSize + (compressed ? count * 4 : 0)
        var frames: [DecodedImage] = []
        for length in lengths {
            let decoded = try decodePayload(buffer, offset: payloadOffset, length: length, sign: sign, width: width, height: height)
            frames.append(DecodedImage(
                rgba: decoded.rgba,
                width: width,
                height: height,
                sign: sign,
                encodedLength: length,
                compressed: decoded.compressed
            ))
            payloadOffset += length
        }
        return frames
    }

    // MARK: - Helpers

    private static func makeCGImage(from image: O66RgbaImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(image.rgba) as CFData) else { return nil }
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func unpremultiply(_ image: inout O66RgbaImage) {
        var offset = 0
        while offset < image.rgba.count {
            let alpha = Int(image.rgba[offset + 3])
            if alpha > 0 && alpha < 255 {
                image.rgba[offset] = UInt8(min(255, (Int(image.rgba[offset]) * 255) / alpha))
                image.rgba[offset + 1] = UInt8(min(255, (Int(image.rgba[offset + 1]) * 255) / alpha))
                image.rgba[offset + 2] = UInt8(min(255, (Int(image.rgba[offset + 2]) * 255) / alpha))
            } else if alpha == 0 {
                image.rgba[offset] = 0
                image.rgba[offset + 1] = 0
                image.rgba[offset + 2] = 0
            }
            offset += 4
        }
    }

    /// Loads a raster image for the band: decoded, fill-scale center-cropped,
    /// optionally rounded and opacity-baked.
    static func processed(_ pngData: Data, width: Int, height: Int, radius: Int, alpha: Int) throws -> O66RgbaImage {
        var image = try rgba(from: pngData)
        image = fillScaled(image, width: width, height: height)
        image = rounded(image, radius: radius)
        image = applyingOpacity(image, alpha: alpha)
        return image
    }
}