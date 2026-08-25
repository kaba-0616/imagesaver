import Foundation
import Photos

/// Everything the grouping needs about one photo. Deliberately small: a
/// library of tens of thousands has to fit in memory all at once, and nothing
/// here is an image.
struct PhotoFingerprint: Codable, Equatable {
    let localIdentifier: String
    let coarse: UInt64
    let fine: FineHash
    let width: Int
    let height: Int
    let creationDate: Date?
    /// Part of the cache key: an edited photo keeps its identifier but is a
    /// different picture.
    let modificationDate: Date?
    let burstIdentifier: String?
    let isFavorite: Bool
    let isScreenshot: Bool
    /// Filled in later, for the few hundred photos that survive grouping, and
    /// only ever shown or sorted by -- never used to decide what is a
    /// duplicate. Optional with a default on purpose: a non-optional field
    /// would fail to decode every cache file written before it existed, and
    /// the user would be made to scan the whole library again.
    var byteCount: Int64?
    /// Brightness profiles for crop detection. See `ImageHash.cropProfiles`.
    /// Optional for the same reason as `byteCount`: a photo without one is
    /// simply left out of crop matching rather than forcing a rescan.
    let colProfile: Data?
    let rowProfile: Data?

    init(localIdentifier: String,
         coarse: UInt64,
         fine: FineHash,
         width: Int,
         height: Int,
         creationDate: Date?,
         modificationDate: Date?,
         burstIdentifier: String?,
         isFavorite: Bool,
         isScreenshot: Bool,
         byteCount: Int64? = nil,
         colProfile: Data? = nil,
         rowProfile: Data? = nil) {
        self.localIdentifier = localIdentifier
        self.coarse = coarse
        self.fine = fine
        self.width = width
        self.height = height
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.burstIdentifier = burstIdentifier
        self.isFavorite = isFavorite
        self.isScreenshot = isScreenshot
        self.byteCount = byteCount
        self.colProfile = colProfile
        self.rowProfile = rowProfile
    }

    /// Compared before two photos are called similar. A portrait and a
    /// landscape squashed onto the same 9×8 grid can score alike without
    /// looking alike.
    var aspect: Double {
        guard width > 0, height > 0 else { return 0 }
        return Double(width) / Double(height)
    }

    var pixels: Int { width * height }
}

/// Fingerprints kept between runs, so opening the screen a second time does
/// not re-read every thumbnail in the library.
enum FingerprintCache {

    /// Bump when a field is added that old cache entries cannot fill in on
    /// their own (an edit re-triggers `isFresh` and recomputes one photo, but
    /// nothing ever re-touches an unmodified one). Crop detection's row/column
    /// profiles are exactly that: without this, every photo scanned before the
    /// upgrade would sit at `colProfile == nil` forever.
    private static let currentVersion = 2
    private static let versionKey = "photoScanCacheVersion"

    private static var fileURL: URL? { PhotoScanStore.url("fingerprints.json") }

    /// `invalidated` is true exactly once per device, the first load after an
    /// upgrade that changed the cache format. The caller logs it -- a silent
    /// full rescan reads as the app having gotten slower for no reason.
    static func load() -> (prints: [String: PhotoFingerprint], invalidated: Bool) {
        let stored = UserDefaults.standard.object(forKey: versionKey) as? Int
        guard stored == currentVersion else {
            UserDefaults.standard.set(currentVersion, forKey: versionKey)
            // Never true on a fresh install (stored == nil, but so is the
            // file): only when a real, populated cache is being thrown away.
            let hadCache = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return ([:], hadCache)
        }
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return ([:], false) }
        let list = (try? JSONDecoder().decode([PhotoFingerprint].self, from: data)) ?? []
        var byID: [String: PhotoFingerprint] = [:]
        byID.reserveCapacity(list.count)
        for print in list { byID[print.localIdentifier] = print }
        return (byID, false)
    }

    /// Losing this file costs a re-scan and nothing else, which is why the
    /// failure is swallowed here and emphatically not in RejectedPairs.
    static func save(_ prints: [PhotoFingerprint]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(prints) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// A cached entry is only good if the photo has not been edited since.
    static func isFresh(_ cached: PhotoFingerprint, for asset: PHAsset) -> Bool {
        cached.modificationDate == asset.modificationDate
            && cached.width == asset.pixelWidth
            && cached.height == asset.pixelHeight
    }
}
