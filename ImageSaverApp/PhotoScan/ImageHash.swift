import UIKit

/// 512 bits of fingerprint, as a run of words -- kept as an array rather than
/// four named fields so the grid can be widened again later (as it already
/// has been once, from 256 to 512 bits) without reshaping this type a second
/// time.
struct FineHash: Hashable, Codable {
    var words: [UInt64]

    func distance(to other: FineHash) -> Int {
        zip(words, other.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
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

    /// 32×16 comparisons (512 bits). Raised from 16×16 (256 bits): a real
    /// 182,000-photo library still turned up a 33-photo group at hamming
    /// distance 0 on the 256-bit hash whose members shared no burst id, were
    /// taken years apart and had unrelated file sizes and resolutions --
    /// different photographs of a similar scene colliding on the hash by
    /// chance, not a chaining bug. Doubling the grid roughly squares the
    /// number of distinct patterns available, which is the direct answer to
    /// two different pictures landing on the same one.
    static func fine(of image: CGImage) -> FineHash? {
        guard let words = bits(of: image, width: 17, height: 32), words.count == 8 else { return nil }
        return FineHash(words: words)
    }

    /// A 16-bin-per-channel RGB histogram from a 32×32 downsample (48 bytes:
    /// R then G then B), compared with the same `meanAbsDifference` the crop
    /// pass already uses on its own brightness profiles -- one distance
    /// function serves both, rather than a second one just for colour.
    /// Existing to catch what neither hash above can: two photographs with a
    /// similar brightness layout (same pose against a plain wall, say) but a
    /// different colour palette, which is exactly the kind of unrelated pair
    /// the fine-hash widening above is meant to separate.
    static func colorHistogram(of image: CGImage) -> Data? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let made: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard made else { return nil }

        let bins = 16
        var r = [Int](repeating: 0, count: bins)
        var g = [Int](repeating: 0, count: bins)
        var b = [Int](repeating: 0, count: bins)
        let pixelCount = side * side
        for index in 0..<pixelCount {
            let offset = index * 4
            r[Int(pixels[offset]) >> 4] += 1
            g[Int(pixels[offset + 1]) >> 4] += 1
            b[Int(pixels[offset + 2]) >> 4] += 1
        }
        func normalized(_ counts: [Int]) -> [UInt8] { counts.map { UInt8(min(255, $0 * 255 / pixelCount)) } }
        return Data(normalized(r) + normalized(g) + normalized(b))
    }

    /// Two brightness profiles for crop detection: `columns` is always 32
    /// samples across the full real width, `rows` is sampled at the same
    /// real-world density so a photo cropped top/bottom out of another one
    /// leaves its row profile as a contiguous slice of the original's -- no
    /// interpolation needed to compare them, just a sliding window.
    ///
    /// A separate, self-contained function rather than a refactor of `bits`
    /// above: `bits` is what the existing, device-verified duplicate judgement
    /// runs on, and this project's history is full of a single misplaced
    /// change taking a build down. A few duplicated lines here cost nothing;
    /// touching `bits` risks the judgement everything else depends on.
    static func cropProfiles(of image: CGImage, realWidth: Int, realHeight: Int) -> (columns: Data, rows: Data)? {
        guard realWidth > 0, realHeight > 0 else { return nil }
        let cols = 32
        let rowCount = min(96, max(8, Int((32.0 * Double(realHeight) / Double(realWidth)).rounded())))

        var pixels = [UInt8](repeating: 0, count: cols * rowCount)
        let made: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: cols,
                height: rowCount,
                bitsPerComponent: 8,
                bytesPerRow: cols,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rowCount))
            return true
        }
        guard made else { return nil }

        var columnSums = [Int](repeating: 0, count: cols)
        var rowBytes = [UInt8](repeating: 0, count: rowCount)
        for y in 0..<rowCount {
            var rowSum = 0
            for x in 0..<cols {
                let value = Int(pixels[y * cols + x])
                columnSums[x] += value
                rowSum += value
            }
            rowBytes[y] = UInt8(rowSum / cols)
        }
        let columnBytes = columnSums.map { UInt8($0 / rowCount) }
        return (Data(columnBytes), Data(rowBytes))
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
