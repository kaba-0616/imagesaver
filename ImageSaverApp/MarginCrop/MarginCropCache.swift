import Foundation

/// One cached verdict for a photo: either the margin found, or an explicit
/// `nil` recorded the last time this ran the detector against it and found
/// nothing. Both prevent re-running `MarginDetector` on an untouched photo
/// the next time the whole library is scanned -- same shape as
/// `FingerprintCache`, one entry per asset rather than one file for the
/// whole library's fingerprints.
struct MarginCropCacheEntry: Codable {
    let modificationDate: Date?
    let width: Int
    let height: Int
    /// The `MarginLevel` this entry was computed at -- a cache hit only
    /// counts as fresh when this still matches the level currently in
    /// effect, otherwise a slider change would silently keep serving
    /// verdicts computed at the old level forever (nothing else about the
    /// photo would have changed to invalidate it).
    let level: Int
    let margin: MarginResult?
}

enum MarginCropCache {

    /// Bump whenever `MarginDetector`'s actual detection behavior changes
    /// (thresholds, the Vision pass, anything that can change what a given
    /// photo at a given level decides) -- not just when `MarginCropCacheEntry`'s
    /// shape changes. A stale verdict from an earlier algorithm version looks
    /// exactly like a fresh one to `isFresh` (same photo, same level), so
    /// changing the algorithm without bumping this meant re-scans kept
    /// serving results computed under the old logic. Bumped to 4: corner
    /// columns/rows are now excluded from the straight-line consistency
    /// check (fixes four-sided borders never being detected), and the
    /// acceptance thresholds were tightened pre-emptively.
    private static let currentVersion = 4
    private static let versionKey = "marginCropCacheVersion"
    private static var fileURL: URL? { PhotoScanStore.url("margincrop.json") }

    static func load() -> [String: MarginCropCacheEntry] {
        let stored = UserDefaults.standard.object(forKey: versionKey) as? Int
        guard stored == currentVersion else {
            UserDefaults.standard.set(currentVersion, forKey: versionKey)
            return [:]
        }
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: MarginCropCacheEntry].self, from: data)) ?? [:]
    }

    /// Losing this file costs a re-scan and nothing else, so a write failure
    /// is swallowed the same way `FingerprintCache.save` swallows one.
    static func save(_ entries: [String: MarginCropCacheEntry]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
