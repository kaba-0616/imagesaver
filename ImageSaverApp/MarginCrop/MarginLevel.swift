import Foundation

/// How strict a margin has to be before this feature calls it one: 0 is loose
/// (catches noisier, less-uniform bars), 10 is strict (only near-perfectly
/// flat bars). Same 0...10 shape as `DuplicateLevel`, but persisted under its
/// own key -- the two sliders control unrelated pipelines and moving one must
/// never touch the other.
///
/// The numeric thresholds below are a first-pass estimate, not a measurement
/// -- there is no ground-truth set of "should this have been caught" photos
/// to tune against ahead of time, the same position `DuplicateLevel`'s
/// thresholds started from before several rounds of on-device adjustment.
/// Expect these to move once real photos have been tried against them.
enum MarginLevel {

    static let range = 0...10
    static let standard = 5

    private static let key = "marginCropLevel"

    static func clamp(_ level: Int) -> Int { min(max(level, range.lowerBound), range.upperBound) }

    static func stored() -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return standard }
        return clamp(UserDefaults.standard.integer(forKey: key))
    }

    static func store(_ level: Int) {
        UserDefaults.standard.set(clamp(level), forKey: key)
    }

    static func detail(for level: Int) -> String {
        switch clamp(level) {
        case 9, 10: return "ほぼ完全に単色の帯だけ"
        case 7, 8: return "はっきりした帯"
        case 4, 5, 6: return "多少のノイズがあっても拾う"
        default: return "かなりゆるく拾う"
        }
    }

    /// Highest allowed sum-of-channel difference (0...765) between an edge
    /// line and the outermost line before the margin is considered broken.
    ///
    /// Everything up to build149 tried to solve false positives with the
    /// *shape* of the boundary (a straight line, corner-robust or not) --
    /// but a real-device run at build149's thresholds still found most of
    /// its ~5,363 candidates were nothing to crop. The reason: a horizon, a
    /// wall/floor edge, or a plain sky is *also* a perfectly straight line
    /// across the whole width, so shape alone cannot separate a real added
    /// border from ordinary photo content. What genuinely sets a synthetic
    /// bar apart is that it is a single, exactly uniform color painted in by
    /// software -- not just "low variance" or "similar-ish", but essentially
    /// flat at the pixel level once JPEG noise is accounted for -- while a
    /// real sky/wall/water, however visually uniform, always carries subtle
    /// continuous variation a synthetic fill never has. This tightens the
    /// per-pixel tolerance drastically (from 45-level*4 to 18-level) to
    /// demand that near-flatness, rather than tuning the shape check further.
    static func colorTolerance(for level: Int) -> Int {
        18 - clamp(level)
    }

    /// Highest allowed per-line color variance before a line is judged too
    /// detailed to be part of a flat margin (a gradient sky, a textured
    /// wall, say). Tightened alongside `colorTolerance`, for the same
    /// "demand actual flatness" reasoning -- from 400-level*35 to
    /// 60-level*5, since a synthetic bar's own variance (JPEG noise on an
    /// otherwise perfectly flat fill) should be far lower than what the
    /// original, much looser limit allowed through.
    static func varianceLimit(for level: Int) -> Int {
        60 - clamp(level) * 5
    }

    /// How far a line's three color channels may spread apart (0 = pure
    /// gray/white/black, 255 = a fully saturated single-channel color)
    /// before it stops counting as a margin at all, regardless of level. A
    /// colored studio backdrop can be exactly as flat and uniform edge to
    /// edge as a real letterbox bar -- this is what keeps that from being
    /// read as one. Not tied to the strictness slider: this feature only
    /// ever claimed to find white/black/gray bars (see the reference photos
    /// this was designed against), so a looser detection level should catch
    /// noisier near-gray bars, not colored backgrounds.
    static let saturationLimit = 30
}
