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
    let margin: MarginResult?
}

enum MarginCropCache {

    /// Bump if `MarginCropCacheEntry`'s shape changes in a way old entries
    /// cannot fill in on their own.
    private static let currentVersion = 1
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
