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
         byteCount: Int64? = nil) {
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

    private static var fileURL: URL? { PhotoScanStore.url("fingerprints.json") }

    static func load() -> [String: PhotoFingerprint] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        let list = (try? JSONDecoder().decode([PhotoFingerprint].self, from: data)) ?? []
        var byID: [String: PhotoFingerprint] = [:]
        byID.reserveCapacity(list.count)
        for print in list { byID[print.localIdentifier] = print }
        return byID
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
