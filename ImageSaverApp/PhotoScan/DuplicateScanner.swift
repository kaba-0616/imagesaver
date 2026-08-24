import Photos
import UIKit

@MainActor
final class DuplicateScanner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case grouping
        case ready
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var groups: [DuplicateGroup] = []
    /// What the scan did, in its own words. Nothing here can be profiled on
    /// the device, and how long a library of this size takes is the one number
    /// the design still rests on a guess for.
    @Published private(set) var report = ""
    @Published private(set) var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var sensitivity: Sensitivity = .standard {
        didSet { if oldValue != sensitivity { regroup() } }
    }

    private var fingerprints: [PhotoFingerprint] = []
    private var scanReport = ""

    private static let queue = DispatchQueue(label: "jp.kaba.imagesaver.photoscan",
                                             qos: .userInitiated)

    var removableCount: Int {
        groups.reduce(0) { $0 + $1.members.count - 1 }
    }

    func requestAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func scan() {
        switch phase {
        case .scanning, .grouping: return
        case .idle, .ready: break
        }
        phase = .scanning(done: 0, total: 0)

        let progress: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor [weak self] in
                guard let self, case .scanning = self.phase else { return }
                self.phase = .scanning(done: done, total: total)
            }
        }
        let finished: @Sendable ([PhotoFingerprint], Int, Int) -> Void = { prints, reused, elapsed in
            Task { @MainActor [weak self] in
                self?.finishScan(prints, reused: reused, milliseconds: elapsed)
            }
        }

        Self.queue.async {
            Self.performScan(progress: progress, finished: finished)
        }
    }

    func regroup() {
        guard fingerprints.count > 1 else {
            groups = []
            phase = .ready
            return
        }
        // Only when there is nothing on screen yet. Changing the sensitivity
        // re-groups too, and swapping the list for a spinner every time the
        // segmented control moves reads as a flicker.
        if phase != .ready { phase = .grouping }
        let snapshot = fingerprints
        let level = sensitivity
        Self.queue.async {
            let started = Date()
            let result = DuplicateGrouper.group(snapshot, sensitivity: level)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Task { @MainActor [weak self] in
                self?.apply(result, milliseconds: elapsed)
            }
        }
    }

    /// The system puts up its own confirmation before anything goes, and it
    /// cannot be suppressed. Deleted photos land in 最近削除した項目 for 30
    /// days -- and, if iCloud photos is on, leave every other device too.
    func delete(_ identifiers: Set<String>) async -> Result<Int, Error> {
        guard !identifiers.isEmpty else { return .success(0) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            fingerprints.removeAll { identifiers.contains($0.localIdentifier) }
            FingerprintCache.save(fingerprints)
            regroup()
            return .success(assets.count)
        } catch {
            return .failure(error)
        }
    }

    private func finishScan(_ prints: [PhotoFingerprint], reused: Int, milliseconds: Int) {
        fingerprints = prints
        scanReport = "\(prints.count)枚を走査 \(milliseconds)ms"
        if reused > 0 { scanReport += " (うち\(reused)枚は前回の結果を再利用)" }
        regroup()
    }

    private func apply(_ result: [DuplicateGroup], milliseconds: Int) {
        groups = result
        let photos = result.reduce(0) { $0 + $1.members.count }
        let largest = result.map(\.members.count).max() ?? 0
        report = scanReport
            + " / 照合 \(milliseconds)ms / \(result.count)組 \(photos)枚"
            + (largest > 0 ? " / 最大の組 \(largest)枚" : "")
        phase = .ready
    }

    // MARK: - Off the main actor

    private nonisolated static func performScan(
        progress: @escaping @Sendable (Int, Int) -> Void,
        finished: @escaping @Sendable ([PhotoFingerprint], Int, Int) -> Void
    ) {
        let started = Date()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let total = assets.count
        progress(0, total)

        var cache = FingerprintCache.load()
        var prints: [PhotoFingerprint] = []
        prints.reserveCapacity(total)
        var reused = 0

        let manager = PHImageManager.default()
        let request = PHImageRequestOptions()
        // fastFormat calls back exactly once, with whatever thumbnail the
        // system already has. isSynchronous would ignore that and decode the
        // full picture instead, which across a whole library is the difference
        // between a scan and an afternoon. Network access stays off: waiting on
        // iCloud would cost the user both time and data.
        request.deliveryMode = .fastFormat
        request.resizeMode = .fast
        request.isNetworkAccessAllowed = false
        let target = CGSize(width: 256, height: 256)

        assets.enumerateObjects { asset, index, _ in
            if let cached = cache[asset.localIdentifier], FingerprintCache.isFresh(cached, for: asset) {
                prints.append(cached)
                reused += 1
            } else if let made = fingerprint(of: asset, manager: manager,
                                             options: request, target: target) {
                prints.append(made)
                cache[asset.localIdentifier] = made
            }
            if index % 25 == 0 { progress(index + 1, total) }
        }

        FingerprintCache.save(prints)
        finished(prints, reused, Int(Date().timeIntervalSince(started) * 1000))
    }

    private nonisolated static func fingerprint(
        of asset: PHAsset,
        manager: PHImageManager,
        options: PHImageRequestOptions,
        target: CGSize
    ) -> PhotoFingerprint? {
        var thumbnail: CGImage?
        let waiter = DispatchSemaphore(value: 0)
        manager.requestImage(for: asset,
                             targetSize: target,
                             contentMode: .aspectFit,
                             options: options) { image, _ in
            thumbnail = image?.cgImage
            waiter.signal()
        }
        // A request that never answers must not stall the whole library.
        _ = waiter.wait(timeout: .now() + 5)

        guard let thumbnail,
              let coarse = ImageHash.coarse(of: thumbnail),
              let fine = ImageHash.fine(of: thumbnail) else { return nil }

        return PhotoFingerprint(
            localIdentifier: asset.localIdentifier,
            coarse: coarse,
            fine: fine,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            burstIdentifier: asset.burstIdentifier,
            isFavorite: asset.isFavorite,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
        )
    }
}
