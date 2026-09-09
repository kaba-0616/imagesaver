import Photos

/// Orchestrates the margin-trim-candidate feature: scan the whole library for
/// photos with a detectable uniform-color margin and let the user browse or
/// dismiss them. A smaller sibling of `DuplicateScanner` -- one detector
/// instead of a grouping pass, and no cross-photo comparison at all, so the
/// pipeline is a single straight loop rather than count → fingerprint →
/// group.
///
/// This used to also *perform* the crop in place, via
/// `PHContentEditingOutput`/`PHAssetChangeRequest`. That write path is gone:
/// every one of 10 independent variables tried against it (Live Photo
/// exclusion, output-format matching, three `adjustmentData` states, a retry,
/// `canHandleAdjustmentData`, EXIF/color-profile preservation, and
/// combinations of these) still failed with `PHPhotosErrorDomain`
/// 3303/3302, confirmed on both a real device and Simulator with clean
/// diagnostics and an instant (tens-of-milliseconds), deterministic
/// rejection at the system level -- see the project plan history for the
/// full trail. The feature is a candidate finder now: it tells the user
/// which photos have a margin worth trimming by hand, rather than trying to
/// commit the edit itself.
@MainActor
final class MarginCropScanner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case counting
        case scanning(done: Int, total: Int, remaining: TimeInterval?)
        case ready
    }

    enum Outcome: Equatable {
        case done
        case failed(String)

        func describe() -> String {
            switch self {
            case .done: return "「トリミングしない」にしました"
            case .failed(let text): return "失敗しました: \(text)"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidates: [MarginCropCandidate] = []
    @Published private(set) var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var level: Int = MarginLevel.stored()
    @Published private(set) var skippedCount = 0
    /// Set right after a "これはトリミングしない" so the view can offer one
    /// step back, the same shape as `DuplicateScanner.canUndoRejection`.
    @Published private(set) var canUndoSkip = false
    /// How many skips back "取り消す" can currently walk -- `canUndoSkip`
    /// alone only says "at least one".
    var undoSkipDepth: Int { skipUndoStack.count }

    private let skipped = MarginCropSkipped()
    /// Up to the last `maxSkipUndoDepth` skips, oldest first -- mirrors
    /// `DuplicateScanner.undoStack`. Kept in memory only (not persisted):
    /// `MarginCropSkipped.decisions`' own order is the thing `undoLast()`
    /// actually removes from, this just remembers which `MarginCropCandidate`
    /// and grid position to hand back to `candidates` when that happens.
    private var skipUndoStack: [(candidate: MarginCropCandidate, position: Int)] = []
    private static let maxSkipUndoDepth = 5
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

    /// Pressing "この設定で再スキャン" is itself an explicit request to
    /// scan again -- skipping the scan whenever the slider happened to land
    /// back on the already-stored level (e.g. re-checking after a detector
    /// change, or wanting to pick up newly added photos) silently did
    /// nothing and gave no feedback that it had, which read as the scan
    /// being stuck rather than as it having never started.
    func commitLevel(_ value: Int) {
        let next = MarginLevel.clamp(value)
        level = next
        MarginLevel.store(next)
        scan()
    }

    func scan() {
        skipped.loadIfNeeded()
        skippedCount = skipped.count
        // A fresh `candidates` array makes every remembered grid position
        // in `skipUndoStack` meaningless -- same reasoning as
        // `DuplicateScanner.forgetUndo()`.
        skipUndoStack.removeAll()
        canUndoSkip = false
        scanToken += 1
        let token = scanToken
        phase = .counting
        let currentLevel = level
        let skippedMargins = skipped.entries

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
            Self.performScan(level: currentLevel, skippedMargins: skippedMargins,
                              counted: counted, progress: progress, finished: finished)
        }
    }

    /// "これはトリミングしない": remembered so the next scan does not offer
    /// *this exact suggestion* again -- see `MarginCropSkipped`'s own
    /// comment on why the margin, not just the identifier, is what gets
    /// recorded.
    func skip(_ candidate: MarginCropCandidate) async -> Outcome {
        guard let position = candidates.firstIndex(where: { $0.id == candidate.id }) else {
            return .failed("写真が見つかりませんでした")
        }
        switch await skipped.add(candidate.localIdentifier, margin: candidate.margin) {
        case .saved:
            candidates.remove(at: position)
            skippedCount = skipped.count
            skipUndoStack.append((candidate, position))
            if skipUndoStack.count > Self.maxSkipUndoDepth { skipUndoStack.removeFirst() }
            canUndoSkip = true
            return .done
        case .busy:
            return .failed("処理中です。少し待ってからもう一度お試しください")
        case .storeFull:
            return .failed("記録できる上限に達しました")
        case .failed(let text):
            return .failed(text)
        }
    }

    /// "取り消す": puts back the most recently skipped candidate, exactly
    /// mirroring `DuplicateScanner.undoRejection()` -- restores the card at
    /// (or as close as possible to, if the list has since shrunk) the grid
    /// position it was removed from.
    func undoSkip() async -> Outcome {
        guard let last = skipUndoStack.last else { return .done }
        switch await skipped.undoLast() {
        case .saved:
            candidates.insert(last.candidate, at: min(last.position, candidates.count))
            skippedCount = skipped.count
            skipUndoStack.removeLast()
            canUndoSkip = !skipUndoStack.isEmpty
            return .done
        case .busy:
            return .failed("処理中です。少し待ってからもう一度お試しください")
        case .storeFull:
            return .failed("記録できる上限に達しました")
        case .failed(let text):
            return .failed(text)
        }
    }

    /// Developer-only: scans the whole library once and reports how many
    /// photos would be offered as candidates at *each* detection level
    /// 0-10, as a single copyable summary -- the same idea as
    /// `MarginDiagnosticView`'s "全レベルをコピー", but for the aggregate
    /// candidate count instead of one photo's edge values. Lets a
    /// sensitivity choice be judged from real counts across the whole
    /// library instead of rescanning by hand eleven times. Does not touch
    /// `MarginCropCache` or `candidates` -- this is a read-only side
    /// report, not a real scan.
    func scanAllLevelsForDevSummary() async -> String {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                Self.computeAllLevelCounts { summary in
                    continuation.resume(returning: summary)
                }
            }
        }
    }

    /// Settings screen: forgets every "これはトリミングしない" decision so
    /// those photos can be offered again on the next scan.
    func clearSkipped() async -> Outcome {
        switch await skipped.removeAll() {
        case .saved:
            skippedCount = 0
            skipUndoStack.removeAll()
            canUndoSkip = false
            return .done
        case .busy:
            return .failed("処理中です。少し待ってからもう一度お試しください")
        case .storeFull:
            return .failed("記録できる上限に達しました")
        case .failed(let text):
            return .failed(text)
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
        skippedMargins: [String: MarginResult],
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
        // Previously-skipped photos are no longer excluded from this count
        // (or from being computed/re-detected below): "don't trim this" was
        // a decision about the specific margin shown at the time, not a
        // blanket exemption from ever being looked at again, so a skipped
        // photo still needs its margin computed (or read from cache) each
        // scan to know whether that decision even still applies -- see
        // where `skippedMargins` is consulted further down.
        var toCompute = 0
        assets.enumerateObjects { asset, _, _ in
            if let cached = cache[asset.localIdentifier], isFresh(cached, for: asset, level: level) { return }
            toCompute += 1
        }
        counted(total)

        var found: [MarginCropCandidate] = []
        // Tallied rather than logged one-by-one: on a library with many
        // skipped photos this branch fires on every single scan for every
        // one of them, which would swamp `PhotoScanLog`'s per-run budget
        // far worse than detection lines ever did. A re-detection at a
        // *different* position is the interesting, comparatively rare
        // event and is still logged individually below.
        var skippedUnchangedCount = 0
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
            if let cached = cache[asset.localIdentifier], isFresh(cached, for: asset, level: level) {
                if let margin = cached.margin {
                    switch skipStatus(margin, for: asset.localIdentifier, width: cached.width, height: cached.height,
                                       skippedMargins: skippedMargins) {
                    case .notSkipped:
                        found.append(MarginCropCandidate(localIdentifier: asset.localIdentifier,
                                                          width: cached.width, height: cached.height,
                                                          creationDate: asset.creationDate,
                                                          margin: margin))
                    case .unchanged:
                        skippedUnchangedCount += 1
                    case .movedFrom(let previous):
                        found.append(MarginCropCandidate(localIdentifier: asset.localIdentifier,
                                                          width: cached.width, height: cached.height,
                                                          creationDate: asset.creationDate,
                                                          margin: margin))
                        let shortID = String(asset.localIdentifier.prefix(8))
                        Task { @MainActor in
                            PhotoScanLog.shared.note(
                                "スキップ済みだが別位置で再検出: \(shortID) "
                                + "前回[上\(previous.top) 下\(previous.bottom) 左\(previous.left) 右\(previous.right)] "
                                + "今回[上\(margin.top) 下\(margin.bottom) 左\(margin.left) 右\(margin.right)]")
                        }
                    }
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
                let status = skipStatus(margin, for: asset.localIdentifier, width: asset.pixelWidth,
                                         height: asset.pixelHeight, skippedMargins: skippedMargins)
                if case .unchanged = status {
                    skippedUnchangedCount += 1
                } else {
                    found.append(MarginCropCandidate(localIdentifier: asset.localIdentifier,
                                                      width: asset.pixelWidth, height: asset.pixelHeight,
                                                      creationDate: asset.creationDate,
                                                      margin: margin))
                    // Only the freshly-computed detections are logged in
                    // detail, not cache hits replayed on every re-scan --
                    // this is meant to be read for tuning the detector
                    // against real photos, and repeating the same line
                    // every run would just bury the new ones. `found.count`
                    // (which does include cache hits) is also what caps how
                    // many detailed lines get written: a library with a few
                    // hundred candidates would otherwise fill
                    // `PhotoScanLog`'s whole per-run budget (300 lines) with
                    // individual detections and silently lose the one line
                    // that actually says how many were found in total --
                    // which is exactly what happened on a real run and
                    // prompted this cap.
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
                            // A photo that was previously "これはトリミングしない"
                            // reappearing here means the detector found it at a
                            // materially different position this time -- worth
                            // calling out explicitly rather than looking like an
                            // ordinary first-time detection.
                            if case .movedFrom(let previous) = status {
                                line += " [スキップ済みだが別位置で再検出: 前回 上\(previous.top) "
                                    + "下\(previous.bottom) 左\(previous.left) 右\(previous.right)]"
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
        }
        // Every 25th photo is reported, so without this the bar stops short
        // of 100% and sits there until `finished` lands.
        progress(total, total, nil)

        if total > 0 { MarginCropCache.save(cache) }
        let foundCount = found.count
        Task { @MainActor in
            var line = "余白スキャン完了: 検出\(foundCount)件"
            if skippedUnchangedCount > 0 {
                line += " (「トリミングしない」のまま除外: \(skippedUnchangedCount)件)"
            }
            PhotoScanLog.shared.note(line)
        }
        finished(found)
    }

    /// One thumbnail fetch per photo, `MarginDetector.detect` run at every
    /// level -- level 0 is the loosest (see `MarginLevel.colorTolerance`/
    /// `minMatchFraction`, both monotonic in level), so a photo `detect`
    /// rejects at level 0 is skipped entirely for the other ten rather than
    /// re-running a detector that can only get stricter from there.
    private nonisolated static func computeAllLevelCounts(completion: @escaping (String) -> Void) {
        let options = PHFetchOptions()
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var counts = [Int](repeating: 0, count: 11)

        let manager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .fastFormat
        requestOptions.resizeMode = .fast
        requestOptions.isNetworkAccessAllowed = false
        let target = CGSize(width: 512, height: 512)

        assets.enumerateObjects { asset, _, _ in
            let box = ThumbnailBox()
            let waiter = DispatchSemaphore(value: 0)
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                  options: requestOptions) { image, _ in
                box.set(image?.cgImage)
                waiter.signal()
            }
            _ = waiter.wait(timeout: .now() + 5)
            guard let cgImage = box.take() else { return }

            let (level0Margin, _, _) = MarginDetector.detect(in: cgImage, realWidth: asset.pixelWidth,
                                                               realHeight: asset.pixelHeight, level: 0)
            guard level0Margin != nil else { return }
            counts[0] += 1
            for level in 1...10 {
                let (margin, _, _) = MarginDetector.detect(in: cgImage, realWidth: asset.pixelWidth,
                                                            realHeight: asset.pixelHeight, level: level)
                if margin != nil { counts[level] += 1 }
            }
        }

        let lines = (0...10).map { "レベル\($0): \(counts[$0])件" }
        let summary = "余白検出件数(全レベル、対象\(assets.count)枚):\n" + lines.joined(separator: "\n")
        completion(summary)
    }

    private enum SkipStatus {
        /// No skip decision recorded for this identifier at all.
        case notSkipped
        /// Skipped, and the freshly-detected margin is still essentially
        /// the same suggestion -- stays excluded.
        case unchanged
        /// Skipped, but the freshly-detected margin has moved to a
        /// materially different position -- this is a different suggestion
        /// the user never actually saw, so it is offered again.
        case movedFrom(MarginResult)
    }

    /// Whether `margin` matches the suggestion this photo was already
    /// dismissed for -- see `MarginCropSkipped`'s comment. `.notSkipped`
    /// whenever there is no recorded skip for this identifier at all.
    private nonisolated static func skipStatus(_ margin: MarginResult, for identifier: String, width: Int, height: Int,
                                                skippedMargins: [String: MarginResult]) -> SkipStatus {
        guard let previous = skippedMargins[identifier] else { return .notSkipped }
        return margin.isEssentiallySame(as: previous, width: width, height: height) ? .unchanged : .movedFrom(previous)
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
