import Photos

/// What a photo costs on disk, and whether its original is on the device.
///
/// Display only. Neither number takes part in deciding what is a duplicate:
/// the app this one replaces groups by file size and puts a beige coat and a
/// pink dress in the same "duplicate" group because both happen to be 122 KB.
struct AssetDetail: Equatable {
    var byteCount: Int64?
    var isLocallyAvailable: Bool?
}

/// PHAsset has no public API for either of these, so both are read through
/// KVC on PHAssetResource. `value(forKey:)` on a key that does not exist
/// raises an Objective-C exception, which Swift cannot catch -- so nothing is
/// asked for without `responds(to:)` saying yes first. KVC looks for the
/// accessors below before it ever reaches the throwing path, so a true from
/// any of them rules the exception out. If Apple removes the key, this
/// degrades to "size unknown" rather than to a crash.
enum AssetDetailReader {

    private static let sizeSelectors = ["getFileSize", "fileSize", "isFileSize", "_fileSize"]
    private static let localSelectors = ["getLocallyAvailable", "locallyAvailable",
                                         "isLocallyAvailable", "_locallyAvailable"]

    /// Only ever called for the photos that survived grouping -- a few hundred
    /// on a normal library. `assetResources(for:)` has no published cost, and
    /// putting an unmeasured synchronous call inside the whole-library loop is
    /// not a bet worth taking when one device round trip costs a day.
    static func details(for identifiers: [String]) -> [String: AssetDetail] {
        guard !identifiers.isEmpty else { return [:] }
        var result: [String: AssetDetail] = [:]
        result.reserveCapacity(identifiers.count)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        assets.enumerateObjects { asset, _, _ in
            result[asset.localIdentifier] = detail(of: asset)
        }
        return result
    }

    static func detail(of asset: PHAsset) -> AssetDetail {
        // Documented to be able to come back empty.
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return AssetDetail(byteCount: nil, isLocallyAvailable: nil) }

        // Every resource, not just the original: an edited photo keeps both
        // copies and a Live Photo keeps a video, and all of it is what
        // deleting the photo would give back.
        var total: Int64 = 0
        for resource in resources {
            if let bytes = byteCount(of: resource) { total += bytes }
        }

        // The original resource can be off the device while a derivative is
        // still here, so any locally present photo resource counts as
        // available.
        var available: Bool?
        for resource in resources where resource.type == .photo || resource.type == .fullSizePhoto {
            if let local = locallyAvailable(resource) {
                available = (available ?? false) || local
            }
        }

        return AssetDetail(byteCount: total > 0 ? total : nil, isLocallyAvailable: available)
    }

    private static func byteCount(of resource: PHAssetResource) -> Int64? {
        guard sizeSelectors.contains(where: { resource.responds(to: NSSelectorFromString($0)) })
        else { return nil }
        // Via NSNumber, never `as? Int64`: the value is an unsigned long long
        // and the direct cast comes back nil depending on how it bridges.
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    private static func locallyAvailable(_ resource: PHAssetResource) -> Bool? {
        guard localSelectors.contains(where: { resource.responds(to: NSSelectorFromString($0)) })
        else { return nil }
        return (resource.value(forKey: "locallyAvailable") as? NSNumber)?.boolValue
    }
}
