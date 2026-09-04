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
    /// Briefly loosened to 90-level*7 in build144 on the theory that the
    /// straight-line consistency check alone was enough of a guard -- a real
    /// device run at that setting found ~48% of an 184k-photo library
    /// "detected" (a clearly absurd rate), so this went back to its original
    /// 60-level*5. What actually needed loosening for "cut closer to the
    /// real edge" was the depth cap/floor below, not how easily something
    /// counts as a margin at all -- conflating the two was the mistake.
    /// Tightened once more, pre-emptively, to 45-level*4: a later run at the
    /// original value found a large-but-uncounted number of candidates (the
    /// per-run log cap swallowed the final count before it could be read --
    /// see `MarginCropScanner`'s detection-log cap), so this moves a step
    /// stricter without data to measure against yet. Revisit once a real
    /// total count is available.
    static func colorTolerance(for level: Int) -> Int {
        45 - clamp(level) * 4
    }

    /// Highest allowed per-line color variance before a line is judged too
    /// detailed to be part of a flat margin (a gradient sky, a textured
    /// wall, say) -- guards low tolerance from still matching real content
    /// that happens to average out near the edge color. Tightened alongside
    /// `colorTolerance` for the same pre-emptive reason.
    static func varianceLimit(for level: Int) -> Int {
        400 - clamp(level) * 35
    }

    /// How far a line's three color channels may spread apart (0 = pure
    /// gray/white/black, 255 = a fully saturated single-channel color)
    /// before it stops counting as a margin at all, regardless of level. A
    /// colored studio backdrop can be exactly as flat and uniform edge to
    /// edge as a real letterbox bar -- this is what keeps that from being
    /// read as one. Not tied to the strictness slider: this feature only
    /// ever claimed to find white/black/gray bars (see the reference photos
    /// this was designed against), so a looser detection level should catch
    /// noisier near-gray bars, not colored backgrounds. Tightened from 40 to
    /// 30 alongside `colorTolerance`, for the same pre-emptive reason --
    /// `MarginDetector`'s Vision pass is only an optional, best-effort
    /// confirmation now (see `reconcile`), not a gate this can lean on.
    static let saturationLimit = 30
}
