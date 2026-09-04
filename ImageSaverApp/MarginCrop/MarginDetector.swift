import UIKit
import Vision

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
    ///
    /// The second element is a short diagnostic note, non-nil only when
    /// Vision's rectangle detector actually changed the outcome (narrowed an
    /// edge the color pass alone found, or confirmed it unchanged) -- meant
    /// to be logged so a real-device run shows which cases Vision affected,
    /// without a line for every photo it never even ran on.
    ///
    /// The third element says whether Vision actually ran (only once the
    /// color pass alone already has a candidate) -- exposed so the caller
    /// can keep a separate time estimate for the Vision-inference photos,
    /// whose per-photo cost is otherwise very different from the majority
    /// that the color pass rejects immediately.
    static func detect(in image: CGImage, realWidth: Int, realHeight: Int, level: Int) -> (MarginResult?, String?, Bool) {
        let sampleWidth = image.width
        let sampleHeight = image.height
        guard sampleWidth > 8, sampleHeight > 8, realWidth > 0, realHeight > 0 else { return (nil, nil, false) }
        guard let rows = pixelRows(of: image, width: sampleWidth, height: sampleHeight) else { return (nil, nil, false) }

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

        // Never eat more than ~60% out of one side -- a genuinely dark or
        // plain photo (a night sky, a studio backdrop) should not be able to
        // vanish entirely just because it is uniform edge to edge. Raised
        // from an initial 45%: the straight-line check already rejects a
        // silhouette-shaped boundary, so this cap only needs to stop a
        // truly edge-to-edge flat photo from disappearing, not second-guess
        // a real bar that happens to be deep.
        let capRows = sampleHeight * 3 / 5
        let capCols = sampleWidth * 3 / 5
        // A margin has to be at least ~1% of that edge's own dimension to
        // count -- a few pixels of compression fringe is not a bar. Lowered
        // from ~1.5% so thin bars are not thrown out before the straight-line
        // check even gets to see them.
        let minRows = max(2, sampleHeight / 100)
        let minCols = max(2, sampleWidth / 100)

        let top = topDepth >= minRows ? min(topDepth, capRows) : 0
        let bottom = bottomDepth >= minRows ? min(bottomDepth, capRows) : 0
        let left = leftDepth >= minCols ? min(leftDepth, capCols) : 0
        let right = rightDepth >= minCols ? min(rightDepth, capCols) : 0
        guard top > 0 || bottom > 0 || left > 0 || right > 0 else { return (nil, nil, false) }

        let pixelResult = (top: top, bottom: bottom, left: left, right: right)

        // Vision is only ever asked to confirm or narrow a candidate the
        // color pass already found -- so it costs nothing on the large
        // majority of ordinary, margin-free photos that never reach this
        // point.
        let vision = detectRectangle(in: image, sampleWidth: sampleWidth, sampleHeight: sampleHeight)
        let (final, note) = reconcile(pixel: pixelResult, vision: vision,
                                       minRows: minRows, minCols: minCols)
        guard final.top > 0 || final.bottom > 0 || final.left > 0 || final.right > 0 else { return (nil, note, true) }

        let scaleX = Double(realWidth) / Double(sampleWidth)
        let scaleY = Double(realHeight) / Double(sampleHeight)
        let result = MarginResult(top: Int((Double(final.top) * scaleY).rounded()),
                                   bottom: Int((Double(final.bottom) * scaleY).rounded()),
                                   left: Int((Double(final.left) * scaleX).rounded()),
                                   right: Int((Double(final.right) * scaleX).rounded()))
        return (result, note, true)
    }

    private typealias EdgeDepths = (top: Int, bottom: Int, left: Int, right: Int)

    /// Combines the color-based candidate with Vision's rectangle. Vision is
    /// an optional confirmation, not a gate on its own: a version that made
    /// it mandatory (drop the whole candidate whenever Vision found nothing
    /// usable) was tried and made things worse on a real device -- genuine
    /// synthetic borders, especially a letterbox/pillarbox where two of the
    /// rectangle's four sides coincide with the image's own edges, turned
    /// out to be a *degenerate*, hard-to-confirm case for a detector tuned
    /// to find a document-like shape floating free inside a photo, while an
    /// actual free-floating rectangle inside an ordinary photo (a sign, a
    /// window, a screen) -- exactly the source of false positives -- is
    /// precisely what Vision confirms *easily*. Making Vision mandatory
    /// therefore dropped real borders while doing little against the false
    /// positives it was meant to catch. Vision now only ever narrows a
    /// result the strict color-based thresholds already trust on their own;
    /// when Vision has nothing to say, the color result passes through
    /// unchanged.
    private static func reconcile(pixel: EdgeDepths, vision: EdgeDepths?,
                                   minRows: Int, minCols: Int) -> (EdgeDepths, String?) {
        guard let vision else { return (pixel, nil) }

        func agreed(_ pixelDepth: Int, _ visionDepth: Int, floor: Int) -> Int {
            guard pixelDepth > 0, visionDepth >= floor else { return 0 }
            return min(pixelDepth, visionDepth)
        }

        let final: EdgeDepths = (
            top: agreed(pixel.top, vision.top, floor: minRows),
            bottom: agreed(pixel.bottom, vision.bottom, floor: minRows),
            left: agreed(pixel.left, vision.left, floor: minCols),
            right: agreed(pixel.right, vision.right, floor: minCols)
        )
        guard final != pixel else {
            return (final, "Visionが一致を確認")
        }
        return (final, "Visionと不一致のため調整: 色\(pixel) → 採用\(final)")
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

        // Excludes the corners from the straight-line check: when all four
        // edges carry a margin, the columns/rows nearest a corner are also
        // inside the *perpendicular* margin, so the same border color can
        // continue far deeper there than along the true edge (often for the
        // image's entire remaining height/width). That drags the corner
        // samples' depth far away from the middle ones and blows out
        // `spread` below, rejecting a real four-sided border outright --
        // exactly the failure a real-device run showed (only two-sided
        // top/bottom or left/right borders were ever detected, never all
        // four at once). A two-sided border has no such interference, so
        // restricting to the central samples changes nothing for it.
        let cornerFraction = sampleCount / 6
        let sampleRange = cornerFraction..<max(cornerFraction + 1, sampleCount - cornerFraction)

        var depths: [Int] = []
        depths.reserveCapacity(sampleRange.count)
        for sample in sampleRange {
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
        // Slack for anti-aliasing/noise right at the seam -- a real straight
        // bar will not disagree by much from one column to the next; a
        // silhouette disagrees by a lot, since it is tracing a shape, not a
        // line. Briefly loosened to 0.2 in build144, reverted to 0.12; now
        // tightened further to 0.10 pre-emptively (no on-device count to
        // measure against yet -- see `MarginLevel`'s thresholds for the
        // same reasoning) alongside the corner exclusion above.
        let allowedSpread = max(2.0, meanDepth * 0.10)
        guard spread <= allowedSpread else { return 0 }

        // The shallowest column/row is the safe cut line: trusting the
        // average instead could still shave into the one column where the
        // subject actually starts earliest.
        return shallowest
    }

    /// Runs `VNDetectRectanglesRequest` on the same downsample the color
    /// pass already read, and turns the strongest rectangle it finds into
    /// edge depths -- or `nil` if it found nothing usable. Only ever called
    /// after the color pass already has a candidate (see `detect`), so this
    /// cost never touches the majority of a library that has no margin at
    /// all.
    ///
    /// Rejects anything not aligned to the image's own axes: Vision is a
    /// general "find a quadrilateral" detector (a sign, a window, a phone
    /// screen in the shot all qualify), not specifically "find the border
    /// around this canvas" -- what actually narrows it down to that job here
    /// is requiring the result to be a plain, unrotated rectangle, which is
    /// the only shape a synthetic margin can ever produce.
    private static func detectRectangle(in image: CGImage, sampleWidth: Int, sampleHeight: Int) -> EdgeDepths? {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.8
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 8
        request.minimumSize = 0.3
        request.maximumObservations = 1

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNRectangleObservation else { return nil }
        return axisAlignedMargin(from: observation, width: sampleWidth, height: sampleHeight)
    }

    /// `VNRectangleObservation`'s four corners are normalized (0...1, origin
    /// bottom-left). This only accepts a corner set that is (within a small
    /// tolerance) an axis-aligned rectangle -- a tilted or trapezoidal quad
    /// is not something a plain crop can express, and is almost certainly
    /// Vision finding some unrelated rectangular object in the shot rather
    /// than a straight synthetic border.
    private static func axisAlignedMargin(from observation: VNRectangleObservation,
                                           width: Int, height: Int) -> EdgeDepths? {
        let tl = observation.topLeft, tr = observation.topRight
        let bl = observation.bottomLeft, br = observation.bottomRight
        let tolerance: CGFloat = 0.02
        guard abs(tl.y - tr.y) <= tolerance, abs(bl.y - br.y) <= tolerance,
              abs(tl.x - bl.x) <= tolerance, abs(tr.x - br.x) <= tolerance else { return nil }

        let left = Int((min(tl.x, bl.x) * CGFloat(width)).rounded())
        let right = Int(((1 - max(tr.x, br.x)) * CGFloat(width)).rounded())
        let top = Int(((1 - max(tl.y, tr.y)) * CGFloat(height)).rounded())
        let bottom = Int((min(bl.y, br.y) * CGFloat(height)).rounded())
        return (top: max(0, top), bottom: max(0, bottom), left: max(0, left), right: max(0, right))
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
