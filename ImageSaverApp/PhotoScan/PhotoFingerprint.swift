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

    private static var fileURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
            .appendingPathComponent("fingerprints.json")
    }

    static func load() -> [String: PhotoFingerprint] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        let list = (try? JSONDecoder().decode([PhotoFingerprint].self, from: data)) ?? []
        var byID: [String: PhotoFingerprint] = [:]
        byID.reserveCapacity(list.count)
        for print in list { byID[print.localIdentifier] = print }
        return byID
    }

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
