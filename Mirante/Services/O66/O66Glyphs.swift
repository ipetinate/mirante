import CoreGraphics
import CoreText
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders the 0–9 digit frames for a `digitalNumber` widget using the same
/// typography as the live preview: `.system(.semibold, design: .rounded)`
/// with monospaced digits, sized `max(8, height × 0.8)`, tinted by the
/// widget's colour.
enum O66Glyphs {
    /// One transparent frame is appended at index 10 and used by the band to
    /// hide a digit lane (EasyFace's "blank" glyph).
    static let frameCount = 11
    static let blankIndex = frameCount - 1

    /// Fixed cell size for the glyphs of one digit lane.
    static func cellSize(for widget: WidgetItem) -> (width: Int, height: Int) {
        let lanes = max(1, widget.digits)
        let spacing = max(0, widget.spacing)
        let cellWidth = max(1, (widget.width - spacing * (lanes - 1)) / lanes)
        return (cellWidth, widget.height)
    }

    struct FontDescriptor {
        let ctFont: CTFont
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Builds the rounded, monospaced-digit font used by the digit frames.
    static func roundedMonospacedFont(size: CGFloat) -> FontDescriptor? {
        #if os(macOS)
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        #else
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        #endif
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor

        let featureSettings: [CFString: Any] = [
            kCTFontFeatureSettingsAttribute: [
                [
                    kCTFontFeatureTypeIdentifierKey: 6,      // number spacing
                    kCTFontFeatureSelectorIdentifierKey: 0, // monospaced
                ]
            ],
        ]
        let roundDescriptor = CTFontDescriptorCreateCopyWithAttributes(
            descriptor as CTFontDescriptor,
            featureSettings as CFDictionary
        )
        let font = CTFontCreateWithFontDescriptor(roundDescriptor, 0, nil)
        return FontDescriptor(
            ctFont: font,
            ascent: CTFontGetAscent(font),
            descent: CTFontGetDescent(font)
        )
    }

    /// Renders the 0–9 glyphs (each its own RGBA cell) plus the blank frame.
    static func digitFrames(for widget: WidgetItem) -> [O66RgbaImage] {
        let (cellWidth, cellHeight) = cellSize(for: widget)
        let fontSize = max(8, CGFloat(cellHeight) * 0.8)
        guard let font = roundedMonospacedFont(size: fontSize) else {
            return Array(repeating: O66RgbaImage(rgba: [UInt8](repeating: 0, count: cellWidth * cellHeight * 4), width: cellWidth, height: cellHeight), count: frameCount)
        }

        let scale = CGFloat(cellHeight) / (font.ascent + font.descent)
        let effectiveFont: CTFont
        if scale < 1 {
            effectiveFont = CTFontCreateCopyWithAttributes(font.ctFont, fontSize * scale, nil, nil)
        } else {
            effectiveFont = font.ctFont
        }

        let red = CGFloat(widget.colorR) / 255
        let green = CGFloat(widget.colorG) / 255
        let blue = CGFloat(widget.colorB) / 255
        let color = CGColor(red: red, green: green, blue: blue, alpha: 1)
        let attributeKeys = [
            kCTFontAttributeName as String: effectiveFont,
            kCTForegroundColorAttributeName as String: color,
        ] as CFDictionary

        var frames: [O66RgbaImage] = []
        frames.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            var rgba = [UInt8](repeating: 0, count: cellWidth * cellHeight * 4)
            if frame < blankIndex {
                let digit = String(frame)
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, digit as CFString, attributeKeys)!)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(
                          data: &rgba,
                          width: cellWidth,
                          height: cellHeight,
                          bitsPerComponent: 8,
                          bytesPerRow: cellWidth * 4,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      ) else {
                    frames.append(O66RgbaImage(rgba: rgba, width: cellWidth, height: cellHeight))
                    continue
                }
                context.translateBy(x: 0, y: CGFloat(cellHeight))
                context.scaleBy(x: 1, y: -1)
                let x = (CGFloat(cellWidth) - advance) / 2
                let baseline = (CGFloat(cellHeight) - ascent + descent) / 2
                let position = CGPoint(x: x, y: baseline)
                context.textPosition = position
                CTLineDraw(line, context)
                unpremultiplyInPlace(&rgba)
            }
            frames.append(O66RgbaImage(rgba: rgba, width: cellWidth, height: cellHeight))
        }

        let alpha = widget.alpha
        if alpha < 255 {
            frames = frames.map { O66ImageCodec.applyingOpacity($0, alpha: alpha) }
        }
        return frames
    }

    /// Renders the translucent rounded box the live preview draws behind the
    /// digits (`RoundedRectangle(cornerRadius: 4)` filled `black.opacity(0.35)`,
    /// at the widget's own opacity) as a single background image.
    static func digitBackgroundImage(for widget: WidgetItem) -> O66RgbaImage {
        let width = max(1, widget.width)
        let height = max(1, widget.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let radius = min(4, width / 2, height / 2)
        let alpha = min(255, Double(widget.alpha) * 0.35)
        guard alpha > 0 else {
            return O66RgbaImage(rgba: rgba, width: width, height: height)
        }
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
                if distance <= cornerR {
                    let offset = (y * width + x) * 4
                    rgba[offset + 3] = UInt8(round(alpha))
                }
            }
        }
        return O66RgbaImage(rgba: rgba, width: width, height: height)
    }

    private static func unpremultiplyInPlace(_ rgba: inout [UInt8]) {
        var offset = 0
        while offset < rgba.count {
            let alpha = Int(rgba[offset + 3])
            if alpha > 0 && alpha < 255 {
                rgba[offset] = UInt8(min(255, (Int(rgba[offset]) * 255) / alpha))
                rgba[offset + 1] = UInt8(min(255, (Int(rgba[offset + 1]) * 255) / alpha))
                rgba[offset + 2] = UInt8(min(255, (Int(rgba[offset + 2]) * 255) / alpha))
            } else if alpha == 0 {
                rgba[offset] = 0
                rgba[offset + 1] = 0
                rgba[offset + 2] = 0
            }
            offset += 4
        }
    }
}