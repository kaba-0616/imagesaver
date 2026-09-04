import CoreImage
import Photos
import UIKit

/// Orchestrates the margin-trim feature: scan the whole library for photos
/// with a detectable uniform-color margin, then apply or skip each one the
/// user reviews. A smaller sibling of `DuplicateScanner` -- one detector
/// instead of a grouping pass, and no cross-photo comparison at all, so the
/// pipeline is a single straight loop rather than count → fingerprint →
/// group.
@MainActor
final class MarginCropScanner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case counting
        case scanning(done: Int, total: Int, remaining: TimeInterval?)
        case ready
    }

    enum ApplyOutcome: Equatable {
        case done
        case cancelled
        case failed(String)

        func describe() -> String {
            switch self {
            case .done: return "トリミングしました"
            case .cancelled: return "iOSの確認でキャンセルされました"
            case .failed(let text): return "失敗しました: \(text)"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidates: [MarginCropCandidate] = []
    @Published private(set) var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var level: Int = MarginLevel.stored()
    @Published private(set) var skippedCount = 0

    private let skipped = MarginCropSkipped()
    /// Bumped on every `scan()`; a scan whose background pass reports back
    /// after a newer one has started is simply dropped, the same guard
    /// `DuplicateScanner.groupToken` uses for the same reason.
    private var scanToken = 0

    func requestAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Only actually re-scans when the level changed -- unchanged, this is a
    /// no-op, the same shape as `DuplicateScanner.commitLevel`.
    func commitLevel(_ value: Int) {
        let next = MarginLevel.clamp(value)
        guard next != level else { return }
        level = next
        MarginLevel.store(next)
        scan()
    }

    func scan() {
        skipped.loadIfNeeded()
        skippedCount = skipped.count
        scanToken += 1
        let token = scanToken
        phase = .counting
        let currentLevel = level
        let skipSet = skipped.identifiers

        let counted: @Sendable (Int) -> Void = { [weak self] total in
            Task { @MainActor in
                guard let self, self.scanToken == token else { return }
                self.phase = .scanning(done: 0, total: total, remaining: nil)
            }
        }
        let progress: @Sendable (Int, Int, TimeInterval?) -> Void = { [weak self] done, total, remaining in
            Task { @MainActor in
                guard let self, self.scanToken == token else { return }
                self.phase = .scanning(done: done, total: total, remaining: remaining)
            }
        }
        let finished: @Sendable ([MarginCropCandidate]) -> Void = { [weak self] found in
            Task { @MainActor in
                guard let self, self.scanToken == token else { return }
                self.candidates = found
                self.phase = .ready
            }
        }

        Self.queue.async {
            Self.performScan(level: currentLevel, skipped: skipSet,
                              counted: counted, progress: progress, finished: finished)
        }
    }

    /// "これはトリミングしない": remembered so the next scan does not offer
    /// this photo again.
    func skip(_ candidate: MarginCropCandidate) async -> ApplyOutcome {
        switch await skipped.add(candidate.localIdentifier) {
        case .saved:
            candidates.removeAll { $0.id == candidate.id }
            skippedCount = skipped.count
            return .done
        case .busy:
            return .failed("処理中です。少し待ってからもう一度お試しください")
        case .storeFull:
            return .failed("記録できる上限に達しました")
        case .failed(let text):
            return .failed(text)
        }
    }

    /// Settings screen: forgets every "これはトリミングしない" decision so
    /// those photos can be offered again on the next scan.
    func clearSkipped() async -> ApplyOutcome {
        switch await skipped.removeAll() {
        case .saved:
            skippedCount = 0
            return .done
        case .busy:
            return .failed("処理中です。少し待ってからもう一度お試しください")
        case .storeFull:
            return .failed("記録できる上限に達しました")
        case .failed(let text):
            return .failed(text)
        }
    }

    /// Crops in place as a Photos edit -- the original stays reachable
    /// through the system's own "編集を戻す", the same revert story every
    /// other photo-editing app on the device gives the user, rather than a
    /// bespoke undo this app would have to build and maintain itself.
    func apply(_ candidate: MarginCropCandidate) async -> ApplyOutcome {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.localIdentifier], options: nil)
        guard let asset = found.firstObject else { return .failed("写真が見つかりませんでした") }
        guard asset.canPerform(.content) else {
            return .failed("この写真は編集できません")
        }

        let inputOptions = PHContentEditingInputRequestOptions()
        inputOptions.isNetworkAccessAllowed = true
        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: inputOptions) { input, _ in
                continuation.resume(returning: input)
            }
        }
        guard let input, let imageURL = input.fullSizeImageURL,
              let source = CIImage(contentsOf: imageURL) else {
            return .failed("元画像の読み込みに失敗しました")
        }

        let oriented = source.oriented(forExifOrientation: input.fullSizeImageOrientation)
        let cropRect = candidate.cropRect
        // `cropRect` was computed in the asset's own pixelWidth/pixelHeight
        // space (top-left origin, Y down -- the PHAsset/UIKit convention).
        // CIImage's coordinate space is bottom-left, Y up, so the Y origin is
        // flipped here. Anchored on `extent.minX`/`.maxY` rather than
        // assuming the extent starts at (0, 0): `.oriented(forExifOrientation:)`
        // can shift the image to a non-zero origin, and measuring from a
        // fixed origin left a strip of the original margin uncropped on one
        // edge (or clipped into real content on the opposite one) whenever
        // that offset was non-zero.
        let extent = oriented.extent
        let ciCropRect = CGRect(x: extent.minX + cropRect.minX,
                                 y: extent.maxY - cropRect.maxY,
                                 width: cropRect.width,
                                 height: cropRect.height)
        let cropped = oriented.cropped(to: ciCropRect)

        guard let cgImage = CIContext().createCGImage(cropped, from: cropped.extent) else {
            return .failed("トリミング画像の生成に失敗しました")
        }
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
            return .failed("画像の書き出しに失敗しました")
        }

        // `PHContentEditingOutput` has no format property to set -- Photos
        // determines the rendered content's format by reading the file
        // itself, so writing valid JPEG bytes to `renderedContentURL` is
        // sufficient regardless of whether the original was JPEG or HEIC.
        let output = PHContentEditingOutput(contentEditingInput: input)
        do {
            try data.write(to: output.renderedContentURL, options: .atomic)
        } catch {
            return .failed(error.localizedDescription)
        }
        // Identifies this app's own edits without claiming to be able to
        // re-derive them -- there is no "recompute the crop" path today, only
        // the system's own revert-to-original.
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "jp.kaba.imagesaver.margincrop",
                                                  formatVersion: "1", data: Data())

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            }
            candidates.removeAll { $0.id == candidate.id }
            return .done
        } catch {
            if (error as NSError).code == NSUserCancelledError { return .cancelled }
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Off the main actor

    private static let queue = DispatchQueue(label: "jp.kaba.imagesaver.margincrop.scan", qos: .userInitiated)

    private nonisolated static func performScan(
        level: Int,
        skipped: Set<String>,
        counted: @escaping @Sendable (Int) -> Void,
        progress: @escaping @Sendable (Int, Int, TimeInterval?) -> Void,
        finished: @escaping @Sendable ([MarginCropCandidate]) -> Void
    ) {
        let started = CFAbsoluteTimeGetCurrent()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let total = assets.count

        var cache = MarginCropCache.load()

        // Same two-population estimate DuplicateScanner.performScan uses:
        // a cache hit costs nothing next to actually fetching and detecting,
        // so averaging them together would make an early estimate wrong by a
        // mile. This first pass only asks "is it already cached", nothing
        // decoded yet.
        var toCompute = 0
        assets.enumerateObjects { asset, _, _ in
            guard !skipped.contains(asset.localIdentifier) else { return }
            if let cached = cache[asset.localIdentifier], isFresh(cached, for: asset) { return }
            toCompute += 1
        }
        counted(total)

        var found: [MarginCropCandidate] = []
        var computeAverage: TimeInterval = 0
        var computeSamples = 0
        var reuseAverage: TimeInterval = 0
        var reuseSamples = 0
        let smoothing = 0.1

        let manager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        // .fastFormat / no network, same reasoning as DuplicateScanner's own
        // library-wide pass: waiting on iCloud across a whole library costs
        // the user time and data for a feature that is only ever a suggestion.
        requestOptions.deliveryMode = .fastFormat
        requestOptions.resizeMode = .fast
        requestOptions.isNetworkAccessAllowed = false
        let target = CGSize(width: 512, height: 512)

        assets.enumerateObjects { asset, index, _ in
            let itemStarted = CFAbsoluteTimeGetCurrent()
            var wasComputed = false
            defer {
                let spent = CFAbsoluteTimeGetCurrent() - itemStarted
                if wasComputed {
                    computeAverage = computeSamples == 0 ? spent : computeAverage + smoothing * (spent - computeAverage)
                    computeSamples += 1
                } else {
                    reuseAverage = reuseSamples == 0 ? spent : reuseAverage + smoothing * (spent - reuseAverage)
                    reuseSamples += 1
                }
                if index % 25 == 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - started
                    let toReuse = max(0, total - toCompute)
                    let negligible = max(20, total / 100)
                    let sampled = (toCompute < negligible || computeSamples >= min(20, toCompute))
                        && (toReuse < negligible || reuseSamples >= min(20, toReuse))
                    var remaining: TimeInterval?
                    if sampled && elapsed >= 2 {
                        let computeLeft = max(0, toCompute - computeSamples)
                        let reuseLeft = max(0, toReuse - reuseSamples)
                        remaining = Double(computeLeft) * computeAverage + Double(reuseLeft) * reuseAverage
                    }
                    progress(index + 1, total, remaining)
                }
            }
            guard !skipped.contains(asset.localIdentifier) else { return }

            if let cached = cache[asset.localIdentifier], isFresh(cached, for: asset) {
                if let margin = cached.margin {
                    found.append(MarginCropCandidate(localIdentifier: asset.localIdentifier,
                                                      width: cached.width, height: cached.height,
                                                      creationDate: asset.creationDate,
                                                      margin: margin))
                }
                return
            }

            wasComputed = true
            let box = ThumbnailBox()
            let waiter = DispatchSemaphore(value: 0)
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                  options: requestOptions) { image, _ in
                box.set(image?.cgImage)
                waiter.signal()
            }
            // Same reasoning as DuplicateScanner.fingerprint(of:): the
            // timeout does not cancel the request, so the box exists to keep
            // a late callback's write off a captured local var.
            _ = waiter.wait(timeout: .now() + 5)

            let margin = box.take().flatMap {
                MarginDetector.detect(in: $0, realWidth: asset.pixelWidth,
                                       realHeight: asset.pixelHeight, level: level)
            }
            cache[asset.localIdentifier] = MarginCropCacheEntry(modificationDate: asset.modificationDate,
                                                                 width: asset.pixelWidth,
                                                                 height: asset.pixelHeight,
                                                                 margin: margin)
            if let margin {
                found.append(MarginCropCandidate(localIdentifier: asset.localIdentifier,
                                                  width: asset.pixelWidth, height: asset.pixelHeight,
                                                  creationDate: asset.creationDate,
                                                  margin: margin))
            }
        }
        // Every 25th photo is reported, so without this the bar stops short
        // of 100% and sits there until `finished` lands.
        progress(total, total, nil)

        if total > 0 { MarginCropCache.save(cache) }
        finished(found)
    }

    private nonisolated static func isFresh(_ entry: MarginCropCacheEntry, for asset: PHAsset) -> Bool {
        entry.modificationDate == asset.modificationDate
            && entry.width == asset.pixelWidth && entry.height == asset.pixelHeight
    }
}

/// One image handed from the Photos callback to the thread waiting on it,
/// under a lock. See `ThumbnailBox` in DuplicateScanner.swift -- duplicated
/// rather than shared because that one is `private` to its file and the
/// isolation reasoning (the scan thread must never inherit @MainActor) is
/// identical either way.
private final class ThumbnailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?

    func set(_ value: CGImage?) {
        lock.lock()
        image = value
        lock.unlock()
    }

    func take() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return image
    }
}
