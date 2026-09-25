import Foundation

/// Xiaomi watchface RLE codecs, ported byte-for-byte from the toolkit's
/// `parser/rle.ts`. v1 repeats whole pixels (used for BGRA images), v2 repeats
/// single palette-index bytes (used for indexed images).
enum O66Rle {
    private static let maxRun = 0x7f

    private static func equalPixel(_ data: [UInt8], _ left: Int, _ right: Int, _ bytesPerPixel: Int) -> Bool {
        for index in 0..<bytesPerPixel where data[left + index] != data[right + index] {
            return false
        }
        return true
    }

    static func encodeV1(_ data: [UInt8], bytesPerPixel: Int) throws -> [UInt8] {
        guard bytesPerPixel >= 1, data.count % bytesPerPixel == 0 else {
            throw O66CompilerError.invalidData("RLE v1 input length \(data.count) is not divisible by bpp \(bytesPerPixel)")
        }

        var output: [UInt8] = []
        var offset = 0
        while offset < data.count {
            var count = 1
            while count < maxRun
                && offset + (count + 1) * bytesPerPixel <= data.count
                && equalPixel(data, offset, offset + count * bytesPerPixel, bytesPerPixel) {
                count += 1
            }
            output.append(UInt8(count))
            for byte in 0..<bytesPerPixel {
                output.append(data[offset + byte])
            }
            offset += count * bytesPerPixel
        }
        return output
    }

    static func decodeV1(_ encoded: [UInt8], expectedLength: Int, bytesPerPixel: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: expectedLength)
        var inputOffset = 0
        var outputOffset = 0

        while inputOffset < encoded.count && outputOffset < output.count {
            let control = encoded[inputOffset]
            inputOffset += 1
            let count = control & UInt8(maxRun)
            if count == 0 { throw O66CompilerError.invalidData("RLE v1 contains a zero-length packet") }

            if control & 0x80 == 0 {
                guard inputOffset + bytesPerPixel <= encoded.count else {
                    throw O66CompilerError.invalidData("Truncated RLE v1 repeat packet")
                }
                let pixel = Array(encoded[inputOffset..<(inputOffset + bytesPerPixel)])
                inputOffset += bytesPerPixel
                for _ in 0..<Int(count) {
                    guard outputOffset + bytesPerPixel <= output.count else {
                        throw O66CompilerError.invalidData("RLE v1 expands beyond its declared size")
                    }
                    output.replaceSubrange(outputOffset..<(outputOffset + bytesPerPixel), with: pixel)
                    outputOffset += bytesPerPixel
                }
            } else {
                let literalLength = Int(count) * bytesPerPixel
                guard inputOffset + literalLength <= encoded.count, outputOffset + literalLength <= output.count else {
                    throw O66CompilerError.invalidData("Truncated RLE v1 literal packet")
                }
                output.replaceSubrange(outputOffset..<(outputOffset + literalLength), with: encoded[inputOffset..<(inputOffset + literalLength)])
                inputOffset += literalLength
                outputOffset += literalLength
            }
        }

        guard outputOffset == expectedLength else {
            throw O66CompilerError.invalidData("RLE v1 produced \(outputOffset) bytes; expected \(expectedLength)")
        }
        return output
    }

    static func encodeV2(_ data: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var offset = 0

        while offset < data.count {
            var repeatCount = 1
            while repeatCount < maxRun && offset + repeatCount < data.count && data[offset + repeatCount] == data[offset] {
                repeatCount += 1
            }

            if repeatCount >= 3 {
                output.append(UInt8(repeatCount))
                output.append(data[offset])
                offset += repeatCount
                continue
            }

            let literalStart = offset
            offset += repeatCount
            while offset < data.count && offset - literalStart < maxRun {
                var nextRepeat = 1
                while nextRepeat < 3 && offset + nextRepeat < data.count && data[offset + nextRepeat] == data[offset] {
                    nextRepeat += 1
                }
                if nextRepeat >= 3 { break }
                offset += min(nextRepeat, maxRun - (offset - literalStart))
            }
            let literalLength = offset - literalStart
            output.append(UInt8(0x80 | literalLength))
            for index in literalStart..<offset {
                output.append(data[index])
            }
        }

        return output
    }

    static func decodeV2(_ encoded: [UInt8], expectedLength: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: expectedLength)
        var inputOffset = 0
        var outputOffset = 0

        while inputOffset < encoded.count && outputOffset < output.count {
            let control = encoded[inputOffset]
            inputOffset += 1
            let count = Int(control & UInt8(maxRun))
            if count == 0 { throw O66CompilerError.invalidData("RLE v2 contains a zero-length packet") }

            if control & 0x80 != 0 {
                guard inputOffset + count <= encoded.count, outputOffset + count <= output.count else {
                    throw O66CompilerError.invalidData("Truncated RLE v2 literal packet")
                }
                output.replaceSubrange(outputOffset..<(outputOffset + count), with: encoded[inputOffset..<(inputOffset + count)])
                inputOffset += count
                outputOffset += count
            } else {
                guard inputOffset < encoded.count, outputOffset + count <= output.count else {
                    throw O66CompilerError.invalidData("Truncated RLE v2 repeat packet")
                }
                let value = encoded[inputOffset]
                inputOffset += 1
                for index in 0..<count {
                    output[outputOffset + index] = value
                }
                outputOffset += count
            }
        }

        guard outputOffset == expectedLength else {
            throw O66CompilerError.invalidData("RLE v2 produced \(outputOffset) bytes; expected \(expectedLength)")
        }
        return output
    }
}