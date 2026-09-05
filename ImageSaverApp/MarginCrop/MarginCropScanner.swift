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

    /// Shares `PhotoScanLog` with `DuplicateScanner` on purpose -- one log
    /// the user already knows how to copy out of the app, rather than a
    /// second store for this feature alone.
    init() {
        PhotoScanLog.shared.beginRun()
    }

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
        // Every failure path also logs to `PhotoScanLog` -- this method is
        // `@MainActor` already (the whole class is), so unlike
        // `performScan`'s background-thread logging, no `Task { @MainActor
        // in ... }` hop is needed here. Added after a real-device apply
        // failed with nothing recorded to explain why.
        let shortID = String(candidate.localIdentifier.prefix(8))
        let found = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.localIdentifier], options: nil)
        guard let asset = found.firstObject else {
            PhotoScanLog.shared.note("トリミング失敗: \(shortID) 写真が見つかりません")
            return .failed("写真が見つかりませんでした")
        }
        guard asset.canPerform(.content) else {
            PhotoScanLog.shared.note("トリミング失敗: \(shortID) この写真は編集できません")
            return .failed("この写真は編集できません")
        }
        // A real-device run hit PHPhotosErrorDomain code 3303
        // (PHPhotosErrorMissingResource) from `performChanges` below, on an
        // asset whose crop otherwise looked perfectly ordinary. That error
        // is documented (if thinly) as Photos being unable to find a
        // resource it expected -- Live Photos carry a paired video resource
        // alongside the still image, which a plain JPEG
        // `PHContentEditingOutput` does not account for. Rejecting Live
        // Photos here up front turns an opaque Photos-internal failure into
        // a clear, specific message, rather than waiting for the same
        // opaque error to resurface.
        guard !asset.mediaSubtypes.contains(.photoLive) else {
            PhotoScanLog.shared.note("トリミング失敗: \(shortID) ライブフォトのため未対応")
            return .failed("ライブフォトは現在この方法でトリミングできません")
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
            PhotoScanLog.shared.note("トリミング失敗: \(shortID) 元画像の読み込みに失敗")
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
            PhotoScanLog.shared.note("トリミング失敗: \(shortID) トリミング画像の生成に失敗")
            return .failed("トリミング画像の生成に失敗しました")
        }
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
            PhotoScanLog.shared.note("トリミング失敗: \(shortID) 画像の書き出しに失敗")
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
            PhotoScanLog.shared.note("トリミング失敗: \(shortID) 書き込み失敗: \(error.localizedDescription)")
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
            if (error as NSError).code == NSUserCancelledError {
                PhotoScanLog.shared.note("トリミングキャンセル: \(shortID)")
                return .cancelled
            }
            // The plain description alone was unhelpful for code 3303
            // ("couldn't be completed") -- the domain/code pinned down what
            // it actually was (PHPhotosErrorMissingResource) well before
            // the description did, so both are logged for next time.
            let nsError = error as NSError
            PhotoScanLog.shared.note(
                "トリミング失敗: \(shortID) performChanges失敗: "
                + "\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Off the main actor

    private static let queue = DispatchQueue(label: "jp.kaba.imagesaver.margincrop.scan", qos: .userInitiated)

    /// Which of the two very different costs a freshly-computed (not cached)
    /// photo actually incurred -- see the time-estimate split in
    /// `performScan`.
    private enum ComputeKind { case fast, vision }

    /// Caps the number of detailed "余白検出: ..." lines a single scan
    /// writes -- see `performScan`'s use of it, and the comment above where
    /// it is checked.
    private static let maxDetectionLogLines = 200

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

        Task { @MainActor in
            PhotoScanLog.shared.note("余白スキャン開始: レベル\(level) 対象\(total)枚")
        }

        var cache = MarginCropCache.load()

        // Same two-population estimate DuplicateScanner.performScan uses:
        // a cache hit costs nothing next to actually fetching and detecting,
        // so averaging them together would make an early estimate wrong by a
        // mile. This first pass only asks "is it already cached", nothing
        // decoded yet.
        var toCompute = 0
        assets.enumerateObjects { asset, _, _ in
            guard !skipped.contains(asset.localIdentifier) else { return }
            if let cached = cache[asset.localIdentifier], isFresh(cached, for: asset, level: level) { return }
            toCompute += 1
        }
        counted(total)

        var found: [MarginCropCandidate] = []
        // Split three ways rather than the plain compute/reuse split
        // DuplicateScanner uses: unlike a fingerprint (roughly the same cost
        // regardless of content), "compute" here is itself bimodal -- most
        // photos are rejected by the cheap color pass alone, while the rare
        // ones that reach Vision's inference cost meaningfully more. Lumping
        // both into one average made the remaining-time estimate swing
        // wildly whenever a batch of 25 happened to include a Vision call.
        var fastComputeAverage: TimeInterval = 0
        var fastComputeSamples = 0
        var visionComputeAverage: TimeInterval = 0
        var visionComputeSamples = 0
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
            var computeKind: ComputeKind?
            defer {
                let spent = CFAbsoluteTimeGetCurrent() - itemStarted
                switch computeKind {
                case .fast:
                    fastComputeAverage = fastComputeSamples == 0 ? spent
                        : fastComputeAverage + smoothing * (spent - fastComputeAverage)
                    fastComputeSamples += 1
                case .vision:
                    visionComputeAverage = visionComputeSamples == 0 ? spent
                        : visionComputeAverage + smoothing * (spent - visionComputeAverage)
                    visionComputeSamples += 1
                case nil:
                    reuseAverage = reuseSamples == 0 ? spent : reuseAverage + smoothing * (spent - reuseAverage)
                    reuseSamples += 1
                }
                if index % 25 == 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - started
                    let toReuse = max(0, total - toCompute)
                    let computeSamples = fastComputeSamples + visionComputeSamples
                    let negligible = max(20, total / 100)
                    let sampled = (toCompute < negligible || computeSamples >= min(20, toCompute))
                        && (toReuse < negligible || reuseSamples >= min(20, toReuse))
                    var remaining: TimeInterval?
                    if sampled && elapsed >= 2 {
                        // The share of not-yet-computed photos that will end
                        // up needing Vision is unknown ahead of time (finding
                        // that out costs as much as just computing it), so
                        // it is estimated from the ratio seen so far and
                        // split proportionally across the two buckets.
                        let visionRatio = computeSamples > 0 ? Double(visionComputeSamples) / Double(computeSamples) : 0
                        let computeLeft = Double(max(0, toCompute - computeSamples))
                        let visionLeft = computeLeft * visionRatio
                        let fastLeft = computeLeft - visionLeft
                        let reuseLeft = max(0, toReuse - reuseSamples)
                        remaining = fastLeft * fastComputeAverage + visionLeft * visionComputeAverage
                            + Double(reuseLeft) * reuseAverage
                    }
                    progress(index + 1, total, remaining)
                }
            }
            guard !skipped.contains(asset.localIdentifier) else { return }

            if let cached = cache[asset.localIdentifier], isFresh(cached, for: asset, level: level) {
                if let margin = cached.margin {
                    found.append(MarginCropCandidate(localIdentifier: asset.localIdentifier,
                                                      width: cached.width, height: cached.height,
                                                      creationDate: asset.creationDate,
                                                      margin: margin))
                }
                return
            }

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

            let (margin, note, ranVision) = box.take().map {
                MarginDetector.detect(in: $0, realWidth: asset.pixelWidth,
                                       realHeight: asset.pixelHeight, level: level)
            } ?? (nil, nil, false)
            computeKind = ranVision ? .vision : .fast
            cache[asset.localIdentifier] = MarginCropCacheEntry(modificationDate: asset.modificationDate,
                                                                 width: asset.pixelWidth,
                                                                 height: asset.pixelHeight,
                                                                 level: level,
                                                                 margin: margin)
            if let margin {
                found.append(MarginCropCandidate(localIdentifier: asset.localIdentifier,
                                                  width: asset.pixelWidth, height: asset.pixelHeight,
                                                  creationDate: asset.creationDate,
                                                  margin: margin))
                // Only the freshly-computed detections are logged in detail,
                // not cache hits replayed on every re-scan -- this is meant
                // to be read for tuning the detector against real photos,
                // and repeating the same line every run would just bury the
                // new ones. `found.count` (which does include cache hits) is
                // also what caps how many detailed lines get written: a
                // library with a few hundred candidates would otherwise fill
                // `PhotoScanLog`'s whole per-run budget (300 lines) with
                // individual detections and silently lose the one line that
                // actually says how many were found in total -- which is
                // exactly what happened on a real run and prompted this cap.
                let count = found.count
                if count <= Self.maxDetectionLogLines {
                    let shortID = String(asset.localIdentifier.prefix(8))
                    Task { @MainActor in
                        var line = "余白検出: \(shortID) \(asset.pixelWidth)x\(asset.pixelHeight) "
                            + "上\(margin.top) 下\(margin.bottom) 左\(margin.left) 右\(margin.right)"
                        // Only Vision actually narrowing/dropping an edge is
                        // worth a line of its own; a plain confirmation or a
                        // photo Vision had nothing to say about would just
                        // repeat the same information for every candidate.
                        if let note, note != "Visionが一致を確認" {
                            line += " (\(note))"
                        }
                        PhotoScanLog.shared.note(line)
                    }
                } else if count == Self.maxDetectionLogLines + 1 {
                    Task { @MainActor in
                        PhotoScanLog.shared.note("(以降の検出はログを省略、件数のみ集計)")
                    }
                } else if (count - Self.maxDetectionLogLines) % 200 == 0 {
                    // A running checkpoint independent of the final
                    // "スキャン完了" line -- if the scan never gets to write
                    // that line (the app is killed, the user leaves before
                    // it finishes), this is still there to say how many had
                    // been found so far.
                    Task { @MainActor in
                        PhotoScanLog.shared.note("(集計中) 現在までの検出件数: \(count)件")
                    }
                }
            }
        }
        // Every 25th photo is reported, so without this the bar stops short
        // of 100% and sits there until `finished` lands.
        progress(total, total, nil)

        if total > 0 { MarginCropCache.save(cache) }
        let foundCount = found.count
        Task { @MainActor in
            PhotoScanLog.shared.note("余白スキャン完了: 検出\(foundCount)件")
        }
        finished(found)
    }

    private nonisolated static func isFresh(_ entry: MarginCropCacheEntry, for asset: PHAsset, level: Int) -> Bool {
        entry.modificationDate == asset.modificationDate
            && entry.width == asset.pixelWidth && entry.height == asset.pixelHeight
            && entry.level == level
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
