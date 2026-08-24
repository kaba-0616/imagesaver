import UIKit

/// 256 bits of fingerprint, as four words.
struct FineHash: Hashable, Codable {
    var a: UInt64
    var b: UInt64
    var c: UInt64
    var d: UInt64

    func distance(to other: FineHash) -> Int {
        (a ^ other.a).nonzeroBitCount
            + (b ^ other.b).nonzeroBitCount
            + (c ^ other.c).nonzeroBitCount
            + (d ^ other.d).nonzeroBitCount
    }
}

/// A perceptual fingerprint: the picture shrunk to a grid of grey values, with
/// one bit per neighbouring pair saying which was brighter.
///
/// Chosen over comparing bytes for two reasons. It survives recompression and
/// resizing, so the 750px and the 1200px copy of one photo are recognised as
/// the same picture. And it can be computed from a thumbnail, so it still
/// works when iCloud is holding the original off the device -- which byte
/// comparison cannot do at all.
enum ImageHash {

    /// 8×8 comparisons. Small enough to compare every photo against every
    /// other one without the wait becoming noticeable.
    static func coarse(of image: CGImage) -> UInt64? {
        guard let words = bits(of: image, width: 9, height: 8), words.count == 1 else { return nil }
        return words[0]
    }

    /// 16×16 comparisons. Two different photographs can land on the same 64
    /// bits; on 256 they do not, so this is what "the same picture" is decided
    /// on before anything is offered for deletion.
    static func fine(of image: CGImage) -> FineHash? {
        guard let words = bits(of: image, width: 17, height: 16), words.count == 4 else { return nil }
        return FineHash(a: words[0], b: words[1], c: words[2], d: words[3])
    }

    private static func bits(of image: CGImage, width: Int, height: Int) -> [UInt64]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let made: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard made else { return nil }

        var words: [UInt64] = []
        var current: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    current |= (1 << bit)
                }
                bit += 1
                if bit == 64 {
                    words.append(current)
                    current = 0
                    bit = 0
                }
            }
        }
        if bit > 0 { words.append(current) }
        return words
    }
}
