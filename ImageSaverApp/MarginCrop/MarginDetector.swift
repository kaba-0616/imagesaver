import UIKit

/// Pixel margins detected on one photo's four edges, in the original asset's
/// own pixel coordinates (`realWidth`/`realHeight` passed to `detect`).
/// Independent per edge on purpose: the photographed subject is not assumed
/// to sit centered, so opposite edges can (and often do) carry different
/// widths.
struct MarginResult: Equatable, Codable {
    var top: Int
    var bottom: Int
    var left: Int
    var right: Int

    var isEmpty: Bool { top == 0 && bottom == 0 && left == 0 && right == 0 }

    /// The crop this margin implies, in the same pixel coordinates as the
    /// asset's own `pixelWidth`/`pixelHeight` (top-left origin).
    func cropRect(width: Int, height: Int) -> CGRect {
        CGRect(x: left, y: top,
               width: max(1, width - left - right),
               height: max(1, height - top - bottom))
    }
}

/// Finds a uniform-color margin on each of a photo's four edges
/// independently, by walking in from each edge one line at a time and
/// stopping where the color stops matching the outermost line closely enough.
///
/// A separate, self-contained pass rather than a reuse of
/// `ImageHash.cropProfiles`: that one reduces a photo to a coarse 32-column
/// grayscale grid, tuned to be cheap enough to compare every photo in a
/// library against every other one for *cross-photo* crop detection. This is
/// a different job -- reading one photo's own edge pixels closely enough to
/// trust the last few percent of it -- run once per candidate rather than
/// O(n²) times, so it can afford its own higher-resolution, color-aware pass.
enum MarginDetector {

    /// `image` should already be a modest downsample (the caller decides the
    /// fetch size) -- this reads it at whatever resolution it is given.
    static func detect(in image: CGImage, realWidth: Int, realHeight: Int, level: Int) -> MarginResult? {
        let sampleWidth = image.width
        let sampleHeight = image.height
        guard sampleWidth > 8, sampleHeight > 8, realWidth > 0, realHeight > 0 else { return nil }
        guard let rows = pixelRows(of: image, width: sampleWidth, height: sampleHeight) else { return nil }

        let tolerance = MarginLevel.colorTolerance(for: level)
        let varianceLimit = MarginLevel.varianceLimit(for: level)

        let topDepth = marginDepth(rows: rows, width: sampleWidth, height: sampleHeight,
                                    from: .top, tolerance: tolerance, varianceLimit: varianceLimit)
        let bottomDepth = marginDepth(rows: rows, width: sampleWidth, height: sampleHeight,
                                       from: .bottom, tolerance: tolerance, varianceLimit: varianceLimit)
        let leftDepth = marginDepth(rows: rows, width: sampleWidth, height: sampleHeight,
                                     from: .left, tolerance: tolerance, varianceLimit: varianceLimit)
        let rightDepth = marginDepth(rows: rows, width: sampleWidth, height: sampleHeight,
                                      from: .right, tolerance: tolerance, varianceLimit: varianceLimit)

        // Never eat more than ~45% out of one side -- a genuinely dark or
        // plain photo (a night sky, a studio backdrop) should not be able to
        // vanish entirely just because it is uniform edge to edge.
        let capRows = sampleHeight * 9 / 20
        let capCols = sampleWidth * 9 / 20
        // A margin has to be at least ~1.5% of that edge's own dimension to
        // count -- a few pixels of compression fringe is not a bar.
        let minRows = max(2, sampleHeight * 3 / 200)
        let minCols = max(2, sampleWidth * 3 / 200)

        let top = topDepth >= minRows ? min(topDepth, capRows) : 0
        let bottom = bottomDepth >= minRows ? min(bottomDepth, capRows) : 0
        let left = leftDepth >= minCols ? min(leftDepth, capCols) : 0
        let right = rightDepth >= minCols ? min(rightDepth, capCols) : 0
        guard top > 0 || bottom > 0 || left > 0 || right > 0 else { return nil }

        let scaleX = Double(realWidth) / Double(sampleWidth)
        let scaleY = Double(realHeight) / Double(sampleHeight)
        return MarginResult(top: Int((Double(top) * scaleY).rounded()),
                             bottom: Int((Double(bottom) * scaleY).rounded()),
                             left: Int((Double(left) * scaleX).rounded()),
                             right: Int((Double(right) * scaleX).rounded()))
    }

    private enum Edge { case top, bottom, left, right }

    /// One scanline's average color, its own internal color variance (high
    /// variance means "this line has real content in it", not a flat margin,
    /// regardless of how close its average color is to the edge's), and its
    /// saturation (how far the three channels spread apart -- a colored
    /// studio backdrop can be just as flat and uniform as a real letterbox
    /// bar, but it is not one; only near-white/near-black/gray counts).
    private struct Line { let r: Double; let g: Double; let b: Double; let variance: Double; let saturation: Double }

    private static func line(_ index: Int, rows: [[UInt8]], width: Int, height: Int, edge: Edge) -> Line {
        let isHorizontal = edge == .top || edge == .bottom
        let length = isHorizontal ? width : height
        guard length > 0 else { return Line(r: 0, g: 0, b: 0, variance: 0, saturation: 0) }

        var sumR = 0, sumG = 0, sumB = 0
        var samples: [Double] = []
        samples.reserveCapacity(length)
        for i in 0..<length {
            let (x, y): (Int, Int) = isHorizontal ? (i, index) : (index, i)
            let row = rows[y]
            let offset = x * 4
            let r = Int(row[offset]), g = Int(row[offset + 1]), b = Int(row[offset + 2])
            sumR += r; sumG += g; sumB += b
            samples.append(Double(r + g + b) / 3)
        }
        let count = Double(length)
        let meanR = Double(sumR) / count, meanG = Double(sumG) / count, meanB = Double(sumB) / count
        let mean = (meanR + meanG + meanB) / 3
        let variance = samples.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let saturation = max(meanR, meanG, meanB) - min(meanR, meanG, meanB)
        return Line(r: meanR, g: meanG, b: meanB, variance: variance, saturation: saturation)
    }

    /// Walks in from `edge`, one line at a time, stopping at the first line
    /// that is either too varied to be flat margin, or whose average color
    /// has drifted too far from the outermost line -- whichever comes first.
    private static func marginDepth(rows: [[UInt8]], width: Int, height: Int,
                                     from edge: Edge, tolerance: Int, varianceLimit: Int) -> Int {
        let lineCount = (edge == .top || edge == .bottom) ? height : width
        guard lineCount > 0 else { return 0 }

        let saturationLimit = Double(MarginLevel.saturationLimit)
        let outermost = edge == .bottom || edge == .right ? lineCount - 1 : 0
        let baseline = line(outermost, rows: rows, width: width, height: height, edge: edge)
        guard baseline.variance <= Double(varianceLimit), baseline.saturation <= saturationLimit else { return 0 }

        var depth = 0
        for step in 0..<lineCount {
            let index = edge == .bottom || edge == .right ? lineCount - 1 - step : step
            let current = line(index, rows: rows, width: width, height: height, edge: edge)
            guard current.variance <= Double(varianceLimit), current.saturation <= saturationLimit else { break }
            let diff = abs(current.r - baseline.r) + abs(current.g - baseline.g) + abs(current.b - baseline.b)
            guard diff <= Double(tolerance) else { break }
            depth = step + 1
        }
        return depth
    }

    /// `rows[y]` is one scanline of `width*4` bytes (RGB + one padding byte
    /// per pixel) -- 24bpp/no-alpha is not one of the pixel formats
    /// `CGBitmapContext` actually supports, so this uses the same 32bpp
    /// `.noneSkipLast` layout `ImageHash.colorHistogram` already relies on,
    /// and simply ignores the 4th byte when reading a pixel back out.
    private static func pixelRows(of image: CGImage, width: Int, height: Int) -> [[UInt8]]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let made: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard made else { return nil }
        var rows: [[UInt8]] = []
        rows.reserveCapacity(height)
        for y in 0..<height {
            let start = y * width * 4
            rows.append(Array(pixels[start..<(start + width * 4)]))
        }
        return rows
    }
}
