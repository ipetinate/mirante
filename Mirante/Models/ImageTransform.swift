import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Pure CoreGraphics image operations used to fix the orientation of imported
/// images. Everything is a lossless re-encode to PNG and independent of
/// UIKit/AppKit, so the results are identical on iOS and macOS and stay
/// consistent across the canvas, the live preview, autosave and export.
enum ImageTransform {
    /// Bakes any EXIF orientation into the pixel data so the image always
    /// decodes upright. Returns the input bytes unchanged when there is no
    /// orientation to apply, so already-correct images keep their original
    /// encoding untouched.
    static func normalized(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let orientation = exifOrientation(src), orientation != 1 else { return data }
        guard let (w, h) = pixelSize(src) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return pngData(from: upright)
    }

    /// Rotates an upright image clockwise by `quarterTurns` (1 = 90°).
    /// A multiple of 4 returns the input unchanged.
    static func rotated(_ data: Data, quarterTurnsClockwise: Int) -> Data? {
        let q = ((quarterTurnsClockwise % 4) + 4) % 4
        guard q != 0 else { return data }
        guard let image = decodedImage(data) else { return nil }
        return render(image, quarterTurns: q, mirrorHorizontal: false, mirrorVertical: false)
    }

    /// Mirrors an upright image left↔right when `horizontal` is true,
    /// otherwise top↔bottom.
    static func mirrored(_ data: Data, horizontal: Bool) -> Data? {
        guard let image = decodedImage(data) else { return nil }
        return render(
            image,
            quarterTurns: 0,
            mirrorHorizontal: horizontal,
            mirrorVertical: !horizontal
        )
    }

    // MARK: - Rendering

    private static func decodedImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func exifOrientation(_ src: CGImageSource) -> Int? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyOrientation] as? Int
    }

    private static func pixelSize(_ src: CGImageSource) -> (Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Rotates the source about the output center by `quarterTurns * 90°`
    /// (clockwise in the final, top-left-origin image) and mirrors it about
    /// its own axes, drawing into a transparent bitmap of the right size.
    private static func render(
        _ image: CGImage,
        quarterTurns: Int,
        mirrorHorizontal: Bool,
        mirrorVertical: Bool
    ) -> Data? {
        let swap = quarterTurns % 2 == 1
        let outW = swap ? image.height : image.width
        let outH = swap ? image.width : image.height
        guard let ctx = bitmapContext(width: outW, height: outH) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: outW, height: outH))

        // Rotate about the output center. Negative angle = clockwise, which is
        // what `quarterTurns` expresses.
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
        ctx.scaleBy(x: mirrorHorizontal ? -1 : 1, y: mirrorVertical ? -1 : 1)
        ctx.draw(image, in: CGRect(
            x: -CGFloat(image.width) / 2,
            y: -CGFloat(image.height) / 2,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        ))

        return pngData(from: ctx.makeImage())
    }

    private static func pngData(from image: CGImage?) -> Data? {
        guard let image else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}