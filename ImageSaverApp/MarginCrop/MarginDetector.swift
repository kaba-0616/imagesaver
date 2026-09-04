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
/// independently, by requiring the boundary between the margin and the real
/// photo to be a straight line all the way across -- see `marginDepth`.
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

    /// A synthetic bar added to the whole image crosses every column (for a
    /// top/bottom edge) or every row (for a left/right edge) at very nearly
    /// the same depth -- it is a straight seam by construction. A photo's
    /// own background, even when it is just as uniformly colored, only
    /// continues until the subject's silhouette interrupts it, and a
    /// silhouette is not a straight line: how far the background goes before
    /// hitting hair, a raised arm, a shoulder varies from column to column.
    /// This measures each column/row's own depth independently and only
    /// trusts the result when those depths agree closely enough to call the
    /// boundary a straight line -- which is what a colored studio backdrop,
    /// however uniform, essentially never manages to do across the whole
    /// width or height at once.
    private static func marginDepth(rows: [[UInt8]], width: Int, height: Int,
                                     from edge: Edge, tolerance: Int, varianceLimit: Int) -> Int {
        let isHorizontal = edge == .top || edge == .bottom
        let lineCount = isHorizontal ? height : width
        let sampleCount = isHorizontal ? width : height
        guard lineCount > 0, sampleCount > 0 else { return 0 }

        let saturationLimit = Double(MarginLevel.saturationLimit)
        let outermost = edge == .bottom || edge == .right ? lineCount - 1 : 0
        let baseline = line(outermost, rows: rows, width: width, height: height, edge: edge)
        guard baseline.variance <= Double(varianceLimit), baseline.saturation <= saturationLimit else { return 0 }

        // A 3-wide average across the sample axis, not a single pixel --
        // compression noise on one bare pixel would otherwise stop a column
        // short for no reason connected to where the real edge is.
        func sampledColor(index: Int, sample: Int) -> (r: Double, g: Double, b: Double) {
            var sumR = 0, sumG = 0, sumB = 0, count = 0
            for delta in -1...1 {
                let s = sample + delta
                guard s >= 0, s < sampleCount else { continue }
                let (x, y): (Int, Int) = isHorizontal ? (s, index) : (index, s)
                let row = rows[y]
                let offset = x * 4
                sumR += Int(row[offset]); sumG += Int(row[offset + 1]); sumB += Int(row[offset + 2])
                count += 1
            }
            return (Double(sumR) / Double(count), Double(sumG) / Double(count), Double(sumB) / Double(count))
        }

        var depths: [Int] = []
        depths.reserveCapacity(sampleCount)
        for sample in 0..<sampleCount {
            var depth = 0
            for step in 0..<lineCount {
                let index = edge == .bottom || edge == .right ? lineCount - 1 - step : step
                let pixel = sampledColor(index: index, sample: sample)
                let diff = abs(pixel.r - baseline.r) + abs(pixel.g - baseline.g) + abs(pixel.b - baseline.b)
                guard diff <= Double(tolerance) else { break }
                depth = step + 1
            }
            depths.append(depth)
        }

        let sorted = depths.sorted()
        guard let shallowest = sorted.first, shallowest > 0 else { return 0 }
        let meanDepth = Double(depths.reduce(0, +)) / Double(depths.count)
        let spread = depths.reduce(0.0) { $0 + abs(Double($1) - meanDepth) } / Double(depths.count)
        // A little slack for anti-aliasing/noise right at the seam -- a real
        // straight bar will not disagree by more than a few percent of its
        // own depth from one column to the next; a silhouette disagrees by a
        // lot, since it is tracing a shape, not a line.
        let allowedSpread = max(2.0, meanDepth * 0.12)
        guard spread <= allowedSpread else { return 0 }

        // The shallowest column/row is the safe cut line: trusting the
        // average instead could still shave into the one column where the
        // subject actually starts earliest.
        return shallowest
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
