import Photos
import UIKit

/// What one pass over the library found out about itself. Everything in here
/// is a value, so it can be handed back from the background queue.
private struct ScanOutcome {
    let prints: [PhotoFingerprint]
    let total: Int
    let reused: Int
    let computed: Int
    /// Photos whose thumbnail never arrived, so no fingerprint could be made.
    /// Counted rather than skipped in silence: if iCloud is holding a few
    /// thousand pictures, the group count comes out low for a reason nobody
    /// would otherwise be able to guess at.
    let missing: Int
    let milliseconds: Int
    let memoryMB: Int
    /// True when the fingerprints were deliberately not written to the cache.
    /// Reported rather than left silent: the next scan being slow for no
    /// apparent reason is exactly the kind of thing nobody can explain later.
    let cacheSkipped: Bool
    /// See `FingerprintCache.load`: true only on the one load where the
    /// cache format changed and the whole thing had to be thrown away.
    let cacheInvalidated: Bool
}

@MainActor
final class DuplicateScanner: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// The cheap pass that only reads the cache, so the estimate below can
        /// be made of real numbers instead of a guess.
        case counting
        case scanning(done: Int, total: Int, remaining: TimeInterval?)
        case grouping(fraction: Double, remaining: TimeInterval?)
        case ready
    }

    /// A re-grouping that runs with the results still on screen. It is not a
    /// Phase on purpose: the slider that starts it lives inside the list, and
    /// a phase change takes the list -- and the slider with it -- away from
    /// under the user's finger halfway through an adjustment.
    struct Regrouping: Equatable {
        let fraction: Double
        let remaining: TimeInterval?
    }

    enum DeleteOutcome: Equatable {
        case done(Int)
        case cancelled
        case failed(String)
    }

    enum RejectOutcome: Equatable {
        case done
        /// Another decision is still being written. Saying so is the point:
        /// the press did nothing, and a press that silently does nothing is
        /// how a decision the user believes was kept goes missing.
        case busy
        /// Stored, but the list was rebuilt while it was being stored, so the
        /// card could not be touched by id and the grouping is being redone.
        case listChanged
        case groupTooLarge(Int)
        case storeFull(Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Non-nil only while the results are on screen and being re-grouped.
    @Published private(set) var regrouping: Regrouping?
    @Published private(set) var groups: [DuplicateGroup] = []
    /// Whether the similar tab has been computed at least once for the
    /// current `fingerprints`. The similar pass is the expensive one (up to
    /// 100+ seconds on a large library at a loose level) and is no longer
    /// started automatically after a scan -- this is what the view checks to
    /// decide whether opening the similar tab needs to kick it off.
    private(set) var hasSimilarResult = false
    /// Kept here rather than in the view so that nothing can survive in it
    /// that is no longer on screen. Every path that replaces `groups` prunes
    /// it, which is what stops a photo the user cannot see from being counted
    /// in -- and deleted by -- the delete button.
    @Published private(set) var selected: Set<String> = []
    /// File size and iCloud state, read on demand for what survived grouping.
    @Published private(set) var details: [String: AssetDetail] = [:]
    @Published private(set) var report = ""
    @Published private(set) var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var level: Int = DuplicateLevel.stored()
    @Published private(set) var rejectionCount = 0
    /// Set when a group has just been put aside, so the view can offer one
    /// step back. Cleared by anything else that changes the list.
    @Published private(set) var canUndoRejection = false

    private var fingerprints: [PhotoFingerprint] = []
    private var scanReport = ""
    private let rejections = RejectedPairs()
    /// What the last completed crop pass found, and the snapshot it found it
    /// against. Crop detection does not depend on `level`, so a threshold
    /// change alone leaves this valid -- checked by `cropCacheKey` below
    /// before it is ever handed back in.
    private var cropCache: DuplicateGrouper.CropCache?
    private var cropCacheKey: CropCacheKey?
    private var undoGroup: DuplicateGroup?
    private var undoPosition = 0
    /// Per tab views of `groups`, rebuilt once whenever it changes. Read on
    /// every pass of the body -- several times over for the delete button
    /// alone -- so they cannot be walked out of `groups` each time.
    private var groupsByKind: [DuplicateGroup.Kind: [DuplicateGroup]] = [:]
    private var identifiersByKind: [DuplicateGroup.Kind: Set<String>] = [:]
    /// Monotonic. A slower grouping started earlier must not be allowed to
    /// land on top of a newer one.
    private var groupToken = 0
    /// A regular app is never granted indefinite background execution --
    /// there is no entitlement here that would qualify it for one. This buys
    /// whatever grace period iOS is willing to give (historically tens of
    /// seconds to a few minutes, never guaranteed) before the process is
    /// suspended, so a scan started just before backgrounding has some chance
    /// of reaching a safe point rather than being cut off mid-write.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let queue = DispatchQueue(label: "jp.kaba.imagesaver.photoscan",
                                             qos: .userInitiated)
    /// Separate from `queue` on purpose: size lookups and cache writes used to
    /// share it with grouping, so a slow size fetch over a huge tab could sit
    /// in front of a user-requested regroup and block it before it had even
    /// started -- invisible on the gauge, which has nothing to show for a job
    /// that has not begun.
    private static let ioQueue = DispatchQueue(label: "jp.kaba.imagesaver.photoscan.io",
                                               qos: .utility)

    init() {
        PhotoScanLog.shared.beginRun()
        rejections.loadIfNeeded()
        rejectionCount = rejections.count
        log("画面を開いた / 判定レベル \(level) (ハミング距離 \(DuplicateLevel.distance(for: level))) / 棄却 \(rejectionCount)組")
    }

    var removableCount: Int {
        groups.reduce(0) { $0 + $1.members.count - 1 }
    }

    func groupList(in kind: DuplicateGroup.Kind) -> [DuplicateGroup] {
        groupsByKind[kind] ?? []
    }

    func identifiers(in kind: DuplicateGroup.Kind) -> Set<String> {
        identifiersByKind[kind] ?? []
    }

    /// The only count the delete button is ever allowed to show: what is
    /// selected *and* on the tab in front of the user.
    func selectedIdentifiers(in kind: DuplicateGroup.Kind) -> Set<String> {
        selected.intersection(identifiers(in: kind))
    }

    func requestAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        log("写真アクセス: \(Self.accessLabel(access))")
    }

    // MARK: - Selection

    func toggle(_ identifier: String) {
        if selected.contains(identifier) {
            selected.remove(identifier)
        } else {
            selected.insert(identifier)
        }
    }

    /// Never picks a favourite, and never picks every member of a group: the
    /// bulk action is the one most likely to be used without looking, so it is
    /// the one that has to be conservative.
    func selectAllButBest(in kind: DuplicateGroup.Kind) {
        var next = selected
        var added = 0
        for group in groups where group.kind == kind {
            for member in group.suggestedDelete where !member.isFavorite {
                if next.insert(member.localIdentifier).inserted { added += 1 }
            }
        }
        selected = next
        log("一括選択(\(kind.tabLabel)): \(added)枚を追加 / このタブの選択 \(selectedIdentifiers(in: kind).count)枚")
    }

    func selectGroupButBest(_ group: DuplicateGroup) {
        for member in group.suggestedDelete where !member.isFavorite {
            selected.insert(member.localIdentifier)
        }
    }

    func deselectGroup(_ group: DuplicateGroup) {
        for member in group.members { selected.remove(member.localIdentifier) }
    }

    func clearSelection(in kind: DuplicateGroup.Kind) {
        selected.subtract(identifiers(in: kind))
    }

    // MARK: - Background time

    /// Idempotent: scan() and regroup() both call this, and a scan's own
    /// regroup at the end must not open a second task on top of the one scan()
    /// already holds.
    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PhotoScan") { [weak self] in
            // UIKit calls this on the main thread, but its closure type does
            // not say so to the compiler -- hopped explicitly, the same way
            // every other callback into this class crosses from off the
            // actor, rather than assumed safe because it usually is.
            Task { @MainActor [weak self] in
                self?.log("[!] バックグラウンド時間切れ (iOSがまもなく一時停止します)")
                PhotoScanLog.shared.flush()
                self?.endBackgroundWork()
            }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Crop cache

    /// Cheap enough to compute on every regroup: a scan or a delete always
    /// changes the count, and the identifiers pinned down here are the ones
    /// most likely to move if the snapshot changed in some subtler way. Not a
    /// perfect fingerprint of the array -- a full one would cost as much as
    /// redoing the crop pass it exists to avoid.
    private struct CropCacheKey: Equatable {
        let count: Int
        let firstID: String?
        let lastID: String?
        let rejectedSignature: Int
    }

    private static func computeCropCacheKey(_ prints: [PhotoFingerprint], rejected: [Set<String>]) -> CropCacheKey {
        var signature = rejected.count
        for decision in rejected { signature ^= decision.hashValue }
        return CropCacheKey(count: prints.count,
                            firstID: prints.first?.localIdentifier,
                            lastID: prints.last?.localIdentifier,
                            rejectedSignature: signature)
    }

    /// How much of the last real (non-cached) crop pass's time went to the
    /// crop pass itself, out of the whole grouping. Persisted across launches
    /// because the split is a property of the library and the device, not of
    /// any one run -- so the very first estimate after opening the app fresh
    /// can already be close, instead of starting from a guess every time.
    private static let cropShareKey = "photoScanCropTimeShare"

    private static func storedCropShare() -> Double {
        let value = UserDefaults.standard.double(forKey: cropShareKey)
        return value > 0 ? min(max(value, 0.05), 0.95) : 0.8
    }

    private static func storeCropShare(cropMS: Int, totalMS: Int) {
        guard cropMS > 0, totalMS > 0 else { return }
        let share = min(max(Double(cropMS) / Double(totalMS), 0.05), 0.95)
        UserDefaults.standard.set(share, forKey: cropShareKey)
    }

    // MARK: - Scan

    func scan() {
        switch phase {
        case .counting, .scanning, .grouping: return
        case .idle, .ready: break
        }
        phase = .counting
        // Anything still being grouped belongs to the list this scan replaces.
        // Without this a grouping that lands mid-scan sets .ready, which takes
        // the progress screen away, drops every progress update after it, and
        // lets scan() be started a second time on top of the first.
        groupToken += 1
        regrouping = nil
        beginBackgroundWork()
        log("走査開始 / 権限 \(Self.accessLabel(access))")

        let counted: @Sendable (Int, Int) -> Void = { total, toCompute in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .counting else { return }
                self.phase = .scanning(done: 0, total: total, remaining: nil)
                self.log("対象 \(total)枚 / 新しく計算が必要 \(toCompute)枚")
            }
        }
        let progress: @Sendable (Int, Int, TimeInterval?) -> Void = { done, total, remaining in
            Task { @MainActor [weak self] in
                guard let self, case .scanning = self.phase else { return }
                self.phase = .scanning(done: done, total: total, remaining: remaining)
            }
        }
        let finished: @Sendable (ScanOutcome) -> Void = { outcome in
            Task { @MainActor [weak self] in
                self?.finishScan(outcome)
            }
        }

        let limited = access == .limited
        Self.queue.async {
            Self.performScan(limited: limited,
                             counted: counted,
                             progress: progress,
                             finished: finished)
        }
    }

    func commitLevel(_ value: Int) {
        let next = DuplicateLevel.clamp(value)
        guard next != level else { return }
        level = next
        DuplicateLevel.store(next)
        log("判定レベル変更: \(next) (ハミング距離 \(DuplicateLevel.distance(for: next)))")
        // The level has no bearing on what counts as an exact duplicate, so
        // only the similar tab has anything to redo.
        regroup(note: "レベル変更", kind: .similar)
    }

    #if IMAGESAVER_DEV_TOOLS
    private var sweepTask: Task<Void, Never>?
    var isSweepRunning: Bool { sweepTask != nil }

    /// Reruns the similar pass at every level in turn and leaves the level
    /// back where it started. Development only: dragging the slider eleven
    /// times and waiting after each one to see the whole curve is what this
    /// replaces.
    func runFullLevelSweep() {
        guard sweepTask == nil else { return }
        let originalLevel = level
        sweepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.log("全レベル一括照合を開始")
            for candidate in DuplicateLevel.range {
                self.level = candidate
                self.regroup(note: "全レベル一括照合(レベル\(candidate))", kind: .similar)
                while self.regrouping != nil || self.phase != .ready {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            self.level = originalLevel
            DuplicateLevel.store(originalLevel)
            self.regroup(note: "全レベル一括照合後の復帰", kind: .similar)
            self.log("全レベル一括照合が完了")
            self.sweepTask = nil
        }
    }
    #endif

    /// `kind` is which tab to recompute -- `nil` means both, and only the
    /// initial post-scan pass and a rejection's token-mismatch fallback with
    /// no single group to point at ever ask for that. A manual reload or a
    /// level change both know exactly which tab is in front of the user and
    /// pass that instead, so the other tab's (possibly still-running) result
    /// is never redone or discarded for a change that could not affect it.
    func regroup(note: String, kind: DuplicateGroup.Kind?) {
        forgetUndo()
        // Ahead of the early return, not after it. A grouping in flight belongs
        // to the list being replaced either way, and one that lands after the
        // list has been emptied puts already deleted photos back on screen.
        groupToken += 1
        beginBackgroundWork()

        // Nothing is grouped while a scan is running. The fingerprints this
        // would work from are the ones the scan is in the middle of replacing,
        // and its own re-group at the end covers whatever asked for this one --
        // the level, the rejections and the deletions are all read then. Left
        // to run, it would land .ready on top of the progress screen instead.
        switch phase {
        case .counting, .scanning:
            log("照合(\(note)): 走査中のため、走査の完了後にまとめて行う")
            return
        case .idle, .grouping, .ready:
            break
        }

        guard fingerprints.count > 1 else {
            groups = []
            refreshGroupIndex()
            regrouping = nil
            phase = .ready
            endBackgroundWork()
            return
        }

        let token = groupToken
        let snapshot = fingerprints
        let level = self.level
        let rejectedIdentical = rejections.memberSets(for: .identical)
        let rejectedSimilar = rejections.memberSets(for: .similar)
        let key = Self.computeCropCacheKey(snapshot, rejected: rejectedSimilar)
        let reusableCrop = (key == cropCacheKey) ? cropCache : nil
        let cropTimeShare = Self.storedCropShare()
        // Changing the sensitivity re-groups too, and swapping the results for
        // a full screen spinner every time the slider is let go takes the
        // slider itself off screen. From .ready the list stays put and a thin
        // bar above it carries the progress and the estimate instead.
        if phase == .ready {
            regrouping = Regrouping(fraction: 0, remaining: nil)
        } else {
            regrouping = nil
            phase = .grouping(fraction: 0, remaining: nil)
        }
        // A completed regroup logs itself in `applyIdentical`/`applySimilar`,
        // but until now a started one did not -- so one that never finished
        // (superseded, or the app backgrounded mid-pass) left only silence
        // where the log should explain the gap.
        log("照合(\(note))を開始: \(snapshot.count)枚")

        let runIdentical = kind == nil || kind == .identical
        let runSimilar = kind == nil || kind == .similar

        Self.queue.async {
            // Identical first when both are asked for: it is an O(n) pass
            // against `byExact`/`byBurst` alone, done in a fraction of a
            // second next to the O(n²)+crop pass similar needs, so running
            // it first gets the duplicate tab something to show while the
            // slow one is still working.
            if runIdentical {
                let started = CFAbsoluteTimeGetCurrent()
                let identicalGroups = DuplicateGrouper.groupIdentical(snapshot, rejected: rejectedIdentical)
                let elapsed = PhotoScanFormat.milliseconds(since: started)
                Task { @MainActor [weak self] in
                    self?.applyIdentical(identicalGroups, token: token, milliseconds: elapsed,
                                         isLast: !runSimilar, note: note)
                }
            }
            guard runSimilar else { return }

            let started = CFAbsoluteTimeGetCurrent()
            let progress: @Sendable (Double) -> Void = { fraction in
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                // Nothing is claimed until there is enough of the job behind
                // us for the rate to mean anything.
                let remaining: TimeInterval? = (fraction > 0.05 && fraction < 1 && elapsed > 1)
                    ? elapsed * (1 - fraction) / fraction
                    : nil
                Task { @MainActor [weak self] in
                    self?.updateGrouping(fraction: fraction, remaining: remaining, token: token)
                }
            }
            let result = DuplicateGrouper.groupSimilar(snapshot,
                                                       level: level,
                                                       rejected: rejectedSimilar,
                                                       cropCache: reusableCrop,
                                                       cropTimeShare: cropTimeShare,
                                                       progress: progress)
            let elapsed = PhotoScanFormat.milliseconds(since: started)
            Task { @MainActor [weak self] in
                self?.applySimilar(result, token: token, milliseconds: elapsed,
                                   newCropCacheKey: key, note: note)
            }
        }
    }

    // MARK: - Rejection

    /// "These are not the same photo." Stated about a group, meant about every
    /// pair inside it, and stored as the one decision the user actually made.
    func reject(_ group: DuplicateGroup) async -> RejectOutcome {
        let members = group.members.map(\.localIdentifier)
        // Both read before the await. DuplicateGroup.id is an index into the
        // run of the grouping that produced it, so once a re-group has landed
        // the same id means an entirely different group -- and removing "the
        // group with that id" would take a card the user never pointed at.
        let token = groupToken
        let position = groups.firstIndex(where: { $0.id == group.id }) ?? 0

        // Saved first, then the card goes. A fingerprint can be made again; a
        // judgement about two photographs cannot.
        switch await rejections.add(members, kind: group.kind) {
        case .saved:
            break
        case .busy:
            return .busy
        case .nothingToStore:
            return .failed("この組には記録できる組み合わせがありませんでした")
        case .groupTooLarge(let count):
            return .groupTooLarge(count)
        case .storeFull(let pairs):
            return .storeFull(pairs)
        case .failed(let text):
            log("[!] 棄却の保存に失敗: \(text)")
            return .failed(text)
        }

        rejectionCount = rejections.count

        // The decision is stored either way. What cannot be done across a
        // re-group is touching the list by id, so the list is rebuilt instead
        // -- which leaves this group out anyway, now that the decision is in.
        guard token == groupToken else {
            log("棄却: 保存中に一覧が入れ替わったため、記録だけ残して照合をやり直す")
            regroup(note: "棄却の反映", kind: group.kind)
            return .listChanged
        }

        // No re-grouping: every pair in the group is now excluded, so a fresh
        // pass over it could only ever produce nothing. Removing the card is
        // the whole result.
        groups.removeAll { $0.id == group.id }
        selected.subtract(Set(members))
        refreshGroupIndex()
        undoGroup = group
        undoPosition = min(position, groups.count)
        canUndoRejection = true
        log("棄却: \(members.count)枚 (\(group.kind.label) / 代表 \(PhotoScanFormat.day(group.suggestedKeep.creationDate)))")
        return .done
    }

    func undoRejection() async -> RejectOutcome {
        guard let group = undoGroup else { return .done }
        let token = groupToken
        switch await rejections.undoLast() {
        case .saved:
            break
        case .busy:
            return .busy
        case .nothingToStore:
            return .failed("取り消せる記録が残っていませんでした")
        case .failed(let text):
            log("[!] 棄却の取り消しに失敗: \(text)")
            return .failed(text)
        case .groupTooLarge(let count):
            return .groupTooLarge(count)
        case .storeFull(let pairs):
            return .storeFull(pairs)
        }
        rejectionCount = rejections.count

        // The held card belongs to the generation it was taken out of. If that
        // generation is gone, putting it back would splice a group from one
        // list into another; a re-group brings it back properly instead.
        guard token == groupToken else {
            log("棄却の取り消し: 一覧が入れ替わっていたため照合をやり直す")
            regroup(note: "棄却の取り消し", kind: group.kind)
            return .listChanged
        }
        // A grouping that landed between the rejection and this press can have
        // brought the card back on its own. DuplicateGroup is Identifiable, so
        // inserting it a second time gives ForEach two rows with one id and the
        // rows stop matching the photos under them.
        guard !groups.contains(where: { $0.id == group.id }) else {
            log("棄却の取り消し: 同じ組が既に一覧に戻っていたため照合をやり直す")
            regroup(note: "棄却の取り消し", kind: group.kind)
            return .listChanged
        }
        // Putting the card back is exact: removing the decision restores
        // precisely the state the group was taken out of.
        groups.insert(group, at: min(undoPosition, groups.count))
        refreshGroupIndex()
        forgetUndo()
        log("棄却を取り消した: \(group.members.count)枚")
        return .done
    }

    /// The count shown on the settings sheet for one tab, and the unit that
    /// tab's "すべて解除" clears -- independent of the other tab's, since a
    /// rejection now only ever affects the tab it was pressed on.
    func rejectionCount(in kind: DuplicateGroup.Kind) -> Int {
        rejections.count(for: kind)
    }

    func clearRejections(kind: DuplicateGroup.Kind) async -> RejectOutcome {
        let before = rejections.count(for: kind)
        switch await rejections.removeAll(kind: kind) {
        case .saved:
            break
        case .busy:
            return .busy
        case .nothingToStore:
            return .done
        case .failed(let text):
            log("[!] 棄却の全解除に失敗: \(text)")
            return .failed(text)
        case .groupTooLarge(let count):
            return .groupTooLarge(count)
        case .storeFull(let pairs):
            return .storeFull(pairs)
        }
        rejectionCount = rejections.count
        log("棄却を全解除(\(kind.tabLabel)): \(before)組")
        regroup(note: "棄却の全解除", kind: kind)
        return .done
    }

    // MARK: - Delete

    /// The system puts up its own confirmation before anything goes, and it
    /// cannot be suppressed. Deleted photos land in 最近削除した項目 for 30
    /// days -- and, if iCloud photos is on, leave every other device too.
    /// The tab is a parameter rather than a promise the caller has to keep:
    /// "only what is on the tab in front of the user" is the rule this whole
    /// screen is built on, so it is enforced here, once.
    func delete(_ identifiers: Set<String>, in kind: DuplicateGroup.Kind) async -> DeleteOutcome {
        // Second safety net. Whatever the view believed, only photos in a
        // group on this tab right now can be deleted.
        let targets = identifiers.intersection(self.identifiers(in: kind))
        guard !targets.isEmpty else { return .done(0) }

        let doomed = fingerprints.filter { targets.contains($0.localIdentifier) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(targets), options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            log("削除: 成功 \(assets.count)枚 (選択 \(targets.count)枚)")
            // The only per-photo lines in the log. A deleted photo sits in
            // 最近削除した項目 for 30 days, and the date and the pixel size are
            // what makes one findable again in there.
            for print in doomed {
                log("  削除 \(PhotoScanFormat.day(print.creationDate)) \(PhotoScanFormat.pixels(width: print.width, height: print.height)) \(print.localIdentifier)")
            }
            // Written out now rather than whenever the coalescing gets round
            // to it: these lines name photos that are already gone, and are
            // the only way back to them inside 最近削除した項目.
            PhotoScanLog.shared.flush()
            fingerprints.removeAll { targets.contains($0.localIdentifier) }
            selected.subtract(targets)
            saveFingerprints()
            pruneGroups(removing: targets)
            return .done(assets.count)
        } catch {
            // PHPhotosErrorUserCancelled and NSUserCancelledError are both
            // 3072, and the two cases mean opposite things to whoever reads
            // the log later.
            let text = (error as NSError).description
            if (error as NSError).code == NSUserCancelledError {
                log("削除: iOSの確認でキャンセルされた (\(targets.count)枚)")
                PhotoScanLog.shared.flush()
                return .cancelled
            }
            log("[!] 削除に失敗: \(text)")
            PhotoScanLog.shared.flush()
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Results

    private func finishScan(_ outcome: ScanOutcome) {
        fingerprints = outcome.prints
        // Whatever the similar tab showed was computed from the fingerprints
        // just replaced -- it no longer describes this library.
        hasSimilarResult = false
        scanReport = "\(outcome.total)枚を走査 \(outcome.milliseconds)ms"
        if outcome.reused > 0 { scanReport += " (再利用\(outcome.reused)枚)" }
        log("走査完了: 対象\(outcome.total)枚 / 再利用\(outcome.reused)枚 / 新規\(outcome.computed)枚 / \(outcome.milliseconds)ms / メモリ\(outcome.memoryMB)MB")
        if outcome.missing > 0 {
            log("[!] サムネイルを取得できず指紋を作れなかった写真: \(outcome.missing)枚")
        }
        if outcome.cacheSkipped {
            log("[!] 指紋の保存を見送った: 権限が「選択した写真のみ」のため、見えている\(outcome.total)枚で全体を上書きしない (次回は再計算になる)")
        }
        if outcome.cacheInvalidated {
            log("[!] キャッシュ形式が変わったため全件を再計算した")
        }
        PhotoScanLog.shared.flush()
        // Out of .scanning before the re-group, which refuses to run while a
        // scan is in flight. Both happen in one turn, so nothing is drawn in
        // between.
        phase = .grouping(fraction: 0, remaining: nil)
        // Similar is the expensive pass (100+ seconds on a large library at a
        // loose level) and starting it before the user has even looked at the
        // similar tab read, on device, as an unprompted re-scan. Duplicate is
        // cheap and worth showing immediately; similar waits for the tab to
        // actually be opened (see `DuplicateFinderView`'s tab watcher).
        regroup(note: "走査後の照合", kind: .identical)
    }

    private func updateGrouping(fraction: Double, remaining: TimeInterval?, token: Int) {
        guard token == groupToken else { return }
        if case .grouping = phase {
            phase = .grouping(fraction: fraction, remaining: remaining)
        } else if regrouping != nil {
            regrouping = Regrouping(fraction: fraction, remaining: remaining)
        }
    }

    /// The exact-match/burst pass. Fast enough that on a fresh scan it lands
    /// well before the similar pass finishes -- `isLast` says whether this is
    /// the only pass this `regroup()` asked for (a duplicate-tab-only reload,
    /// say), in which case this is the one that has to close things out.
    private func applyIdentical(_ result: [DuplicateGroup], token: Int, milliseconds: Int,
                                isLast: Bool, note: String) {
        guard token == groupToken else { return }
        replaceGroups(kind: .identical, with: result)

        let photos = result.reduce(0) { $0 + $1.members.count }
        log("照合(\(note)/重複): \(milliseconds)ms / \(result.count)組\(photos)枚 / 棄却\(rejectionCount(in: .identical))組")
        log("重複の組サイズ: " + result.map { String($0.members.count) }.joined(separator: ","))
        updateReport()

        if isLast {
            finishRegroup()
        } else if phase != .ready {
            // The full-screen spinner (a fresh scan's own re-group, never a
            // manual one -- that only ever starts from .ready) has done its
            // job now that there is something to show. The still-running
            // similar pass carries on behind the thin bar over the list
            // instead, the same as any other regroup started from .ready.
            phase = .ready
            regrouping = Regrouping(fraction: 0, remaining: nil)
        }
    }

    private func applySimilar(_ result: DuplicateGrouper.Result, token: Int, milliseconds: Int,
                              newCropCacheKey: CropCacheKey, note: String) {
        guard token == groupToken else { return }
        hasSimilarResult = true
        cropCache = result.cropCache
        cropCacheKey = newCropCacheKey
        if !result.cropReused { Self.storeCropShare(cropMS: result.cropMS, totalMS: milliseconds) }
        replaceGroups(kind: .similar, with: result.groups)

        let photos = result.groups.reduce(0) { $0 + $1.members.count }
        let largest = result.groups.map(\.members.count).max() ?? 0
        let croppedGroups = result.groups.filter { !$0.croppedIdentifiers.isEmpty }.count
        let croppedPhotos = result.groups.reduce(0) { $0 + $1.croppedIdentifiers.count }
        log("照合(\(note)/類似): レベル\(level) ハミング距離\(DuplicateLevel.distance(for: level)) / \(milliseconds)ms / \(result.groups.count)組\(photos)枚 / 最大の組\(largest)枚 / 棄却\(rejectionCount(in: .similar))組")
        if result.cropReused {
            log("トリミング候補: 前回の結果を再利用 (最大の同一幅グループ\(result.largestWidthBucket)枚 / 検査した組\(result.cropCandidatePairs)組)")
        } else {
            log("トリミング候補: 最大の同一幅グループ\(result.largestWidthBucket)枚 / 検査した組\(result.cropCandidatePairs)組 / \(result.cropMS)ms")
        }
        log("トリミング検知: \(croppedGroups)組\(croppedPhotos)枚")
        log("類似の組サイズ: " + result.groups.map { String($0.members.count) }.joined(separator: ","))
        // Below this size a breakdown is just noise; above it, it is the
        // difference between guessing why a group is that size and knowing.
        if let biggest = result.groups.max(by: { $0.members.count < $1.members.count }),
           biggest.members.count >= 20 {
            logLargestGroupComposition(biggest)
        }
        updateReport()

        finishRegroup()
    }

    /// One line describing what the biggest group is actually made of, so a
    /// group that will not shrink no matter how strict the level gets can be
    /// told apart from a real chaining bug without reading raw identifiers.
    private func logLargestGroupComposition(_ group: DuplicateGroup) {
        let members = group.members
        let burstIDs = Set(members.compactMap(\.burstIdentifier))
        let dates = members.compactMap(\.creationDate).sorted()
        let byteCounts = members.compactMap(\.byteCount)
        let dimensions = Set(members.map { "\($0.width)x\($0.height)" })

        var parts = ["\(members.count)枚 / バーストID種類\(burstIDs.count)"]
        if let first = dates.first, let last = dates.last {
            parts.append("撮影日時幅\(Int(last.timeIntervalSince(first)))秒")
        }
        if byteCounts.count == members.count, let min = byteCounts.min(), let max = byteCounts.max() {
            parts.append("バイトサイズ\(min)〜\(max)")
        } else {
            parts.append("バイトサイズ不明\(members.count - byteCounts.count)枚")
        }
        parts.append("解像度種類\(dimensions.count)")
        log("最大の組の内訳: " + parts.joined(separator: " / "))
    }

    /// Swaps in one tab's freshly computed groups, leaving the other tab's
    /// exactly as they were -- the point of splitting the two passes apart.
    private func replaceGroups(kind: DuplicateGroup.Kind, with newGroups: [DuplicateGroup]) {
        groups = groups.filter { $0.kind != kind } + newGroups
        refreshGroupIndex()
        // The list held for the undo came out of the generation before this
        // one. Keeping it would let 取り消す splice a card from the old list
        // into the new one, where the same id can already be present.
        forgetUndo()
    }

    private func updateReport() {
        let identical = groups.filter { $0.kind == .identical }
        let similar = groups.filter { $0.kind == .similar }
        let identicalPhotos = identical.reduce(0) { $0 + $1.members.count }
        let similarPhotos = similar.reduce(0) { $0 + $1.members.count }
        report = scanReport
            + " / 重複 \(identical.count)組 \(identicalPhotos)枚"
            + " / 類似 \(similar.count)組 \(similarPhotos)枚"
        reportMissingSizes(in: groups, pending: true)
    }

    /// The tail both passes share once whichever of them is last has landed.
    private func finishRegroup() {
        regrouping = nil
        phase = .ready
        loadDetails()
        // The next thing to happen might be the app going away -- deleting,
        // closing the screen, or (now that a large library's crop pass can
        // take real time) simply running out of foreground time. A lost 照合
        // line is a line nobody can explain not seeing later.
        PhotoScanLog.shared.flush()
        endBackgroundWork()
    }

    /// Called by everything that replaces `groups`, and the only place either
    /// of the two things below happens.
    ///
    /// It drops anything selected that is no longer on screen -- without that,
    /// a change of level, or a group put aside, leaves photos counted in the
    /// delete button that the user has no way to look at. And it builds the
    /// per-tab lookups in the same walk, because the delete button and the tab
    /// labels ask for them several times per body evaluation and `selected` is
    /// published, so every tick of a checkbox would otherwise walk every
    /// member of every group again.
    /// Deleting can only ever shrink a group: nothing that was unalike
    /// becomes alike because a third picture went away. Re-running the whole
    /// comparison for that cost 19 seconds on a library of 180,000 photos, so
    /// the groups are trimmed where they stand instead.
    private func pruneGroups(removing gone: Set<String>) {
        let started = Date()
        var kept: [DuplicateGroup] = []
        kept.reserveCapacity(groups.count)
        var emptied = 0
        for group in groups {
            let members = group.members.filter { !gone.contains($0.localIdentifier) }
            if members.count == group.members.count {
                kept.append(group)
                continue
            }
            guard members.count > 0 else {
                emptied += 1
                continue
            }
            let stillHere = Set(members.map(\.localIdentifier))
            kept.append(DuplicateGroup(id: group.id,
                                       kind: group.kind,
                                       members: members,
                                       hasRejectedPair: group.hasRejectedPair,
                                       croppedIdentifiers: group.croppedIdentifiers.intersection(stillHere)))
        }
        groups = kept
        refreshGroupIndex()
        forgetUndo()
        let identical = kept.filter { $0.kind == .identical }.count
        let similar = kept.filter { $0.kind == .similar }.count
        log("削除後の整理: \(Int(Date().timeIntervalSince(started) * 1000))ms"
            + " / 0枚になり消えた組 \(emptied)組"
            + " / 重複\(identical)組 / 類似\(similar)組")
    }

    private func refreshGroupIndex() {
        var lists: [DuplicateGroup.Kind: [DuplicateGroup]] = [:]
        var identifiers: [DuplicateGroup.Kind: Set<String>] = [:]
        for kind in DuplicateGroup.Kind.allCases {
            lists[kind] = []
            identifiers[kind] = []
        }
        var onScreen = Set<String>()
        for group in groups {
            lists[group.kind, default: []].append(group)
            for member in group.members {
                identifiers[group.kind, default: []].insert(member.localIdentifier)
                onScreen.insert(member.localIdentifier)
            }
        }
        groupsByKind = lists
        identifiersByKind = identifiers

        guard !selected.isEmpty else { return }
        let kept = selected.intersection(onScreen)
        if kept.count != selected.count { selected = kept }
    }

    private func forgetUndo() {
        undoGroup = nil
        canUndoRejection = false
    }

    // MARK: - Sizes

    /// Only for what survived grouping, and only once per photo. Reading asset
    /// resources for a whole library is an unmeasured cost inside a loop that
    /// already takes the longest of anything here.
    private func loadDetails() {
        var wanted: [String] = []
        var seen = Set<String>()
        for group in groups {
            for member in group.members {
                let identifier = member.localIdentifier
                guard details[identifier] == nil, !seen.contains(identifier) else { continue }
                seen.insert(identifier)
                wanted.append(identifier)
            }
        }
        guard !wanted.isEmpty else {
            // Nothing left to ask for, so whatever is missing now is missing
            // for good and the ordering above was the final one.
            reportMissingSizes(in: groups, pending: false)
            return
        }

        let token = groupToken
        Self.ioQueue.async {
            let started = CFAbsoluteTimeGetCurrent()
            let found = AssetDetailReader.details(for: wanted)
            let elapsed = PhotoScanFormat.milliseconds(since: started)
            Task { @MainActor [weak self] in
                self?.applyDetails(found, token: token, milliseconds: elapsed)
            }
        }
    }

    private func applyDetails(_ found: [String: AssetDetail], token: Int, milliseconds: Int) {
        guard token == groupToken, !found.isEmpty else { return }
        for (identifier, detail) in found { details[identifier] = detail }

        var changed = false
        for index in fingerprints.indices {
            guard let bytes = found[fingerprints[index].localIdentifier]?.byteCount,
                  fingerprints[index].byteCount != bytes else { continue }
            fingerprints[index].byteCount = bytes
            changed = true
        }

        // The sizes go into every card; the order is only redone where nothing
        // has been chosen yet.
        //
        // The pixel count decides first, so most cards no longer move when the
        // sizes land -- but two copies of the same picture at the same pixel
        // count and different file sizes (a HEIC and a JPEG of one photo) still
        // swap places, and the first member is the one labelled 残す候補. A card
        // the user has already ticked through the bulk action would then have
        // 残す候補 land on a photo that is already ticked, and the one file
        // they asked to keep is the one that gets deleted. So a card with any
        // member chosen keeps the order it was chosen under.
        var reordered = 0
        var held = 0
        groups = groups.map { group in
            let updated = group.members.map { member -> PhotoFingerprint in
                var copy = member
                if let bytes = found[member.localIdentifier]?.byteCount { copy.byteCount = bytes }
                return copy
            }
            let touched = group.members.contains { selected.contains($0.localIdentifier) }
            let members: [PhotoFingerprint]
            if touched {
                held += 1
                members = updated
            } else {
                members = DuplicateGrouper.order(updated, croppedIdentifiers: group.croppedIdentifiers)
                if members.first?.localIdentifier != updated.first?.localIdentifier {
                    reordered += 1
                }
            }
            return DuplicateGroup(id: group.id,
                                  kind: group.kind,
                                  members: members,
                                  hasRejectedPair: group.hasRejectedPair,
                                  croppedIdentifiers: group.croppedIdentifiers)
        }
        refreshGroupIndex()
        reportMissingSizes(in: groups, pending: false)

        if changed { saveFingerprints() }
        let unknown = found.values.filter { $0.byteCount == nil }.count
        log("サイズ取得: \(found.count)枚 \(milliseconds)ms / 残す候補が変わった組 \(reordered)組 / 選択済みのため据え置き \(held)組"
            + (unknown > 0 ? " / 不明 \(unknown)枚" : ""))

        // 重複の判定はファイルサイズも同じであることを条件にしているが、走査
        // 直後はまだサイズが分からず nil 同士としてまとめている。ここでサイズが
        // 分かった時点で該当する組が対象なら重複タブだけ組み直し、実は大きさが
        // 違っていた組を分割する。
        let identicalIdentifiers = Set(groups.lazy.filter { $0.kind == .identical }
            .flatMap { $0.members.map(\.localIdentifier) })
        if changed, !identicalIdentifiers.isDisjoint(with: found.keys) {
            regroup(note: "サイズ判明による重複の絞り込み", kind: .identical)
        }
    }

    /// Ranking is 画素数 -> ファイルサイズ -> 撮影日, and the middle step is
    /// dropped for any group where a size could not be read. The sizes arrive
    /// after the grouping does, and they come from a private PHAssetResource
    /// key that can stop answering altogether -- so both the wait and the
    /// permanent absence are said out loud. A rule quietly going missing is
    /// the hardest thing of all to work out from the outside.
    private func reportMissingSizes(in list: [DuplicateGroup], pending: Bool) {
        var affected = 0
        for group in list where !DuplicateGrouper.sizesKnown(group.members) {
            affected += 1
        }
        guard affected > 0 else { return }
        if pending {
            log("順位付け: ファイルサイズがまだ届いていないため解像度と撮影日のみで並べた組 \(affected)組 / 全\(list.count)組 (サイズが届き次第この後で並べ直す)")
        } else {
            log("[!] 順位付け: ファイルサイズを取得できなかったため解像度と撮影日のみで並べた組 \(affected)組 / 全\(list.count)組")
        }
    }

    private func saveFingerprints() {
        // Same reason as the scan: under 選択した写真のみ these fingerprints are
        // only the handful of photos the user picked, and writing them would
        // stand in for the whole library.
        guard access != .limited else {
            log("指紋の保存を見送った: 権限が「選択した写真のみ」のため")
            return
        }
        let snapshot = fingerprints
        Self.ioQueue.async { FingerprintCache.save(snapshot) }
    }

    private func log(_ text: String) {
        PhotoScanLog.shared.note(text)
    }

    static func accessLabel(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "すべての写真"
        case .limited: return "選択した写真のみ"
        case .denied: return "拒否"
        case .restricted: return "制限"
        case .notDetermined: return "未確認"
        @unknown default: return "不明"
        }
    }

    // MARK: - Off the main actor

    private nonisolated static func performScan(
        limited: Bool,
        counted: @escaping @Sendable (Int, Int) -> Void,
        progress: @escaping @Sendable (Int, Int, TimeInterval?) -> Void,
        finished: @escaping @Sendable (ScanOutcome) -> Void
    ) {
        let started = CFAbsoluteTimeGetCurrent()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let total = assets.count

        let loaded = FingerprintCache.load()
        var cache = loaded.prints

        // A first pass that decodes nothing: it only asks the cache whether it
        // already has each photo. That turns "how much of this is new" from a
        // guess into a number, which is the whole basis of the estimate below
        // -- a plain average is wrong by a mile early on, because the reused
        // ones cost nothing and the new ones cost everything.
        var toCompute = 0
        assets.enumerateObjects { asset, _, _ in
            if let cached = cache[asset.localIdentifier], FingerprintCache.isFresh(cached, for: asset) {
                return
            }
            toCompute += 1
        }
        counted(total, toCompute)

        var prints: [PhotoFingerprint] = []
        prints.reserveCapacity(total)
        var reused = 0
        var computed = 0
        var missing = 0
        // One moving average per population. Mixing them is what makes the
        // first estimate absurd.
        var computeAverage: TimeInterval = 0
        var computeSamples = 0
        var reuseAverage: TimeInterval = 0
        var reuseSamples = 0
        let smoothing = 0.1

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
            let itemStarted = CFAbsoluteTimeGetCurrent()
            var wasComputed = false

            if let cached = cache[asset.localIdentifier], FingerprintCache.isFresh(cached, for: asset) {
                prints.append(cached)
                reused += 1
            } else {
                wasComputed = true
                if let made = fingerprint(of: asset, manager: manager,
                                          options: request, target: target) {
                    prints.append(made)
                    cache[asset.localIdentifier] = made
                    computed += 1
                } else {
                    missing += 1
                }
            }

            let spent = CFAbsoluteTimeGetCurrent() - itemStarted
            if wasComputed {
                computeAverage = computeSamples == 0
                    ? spent
                    : computeAverage + smoothing * (spent - computeAverage)
                computeSamples += 1
            } else {
                reuseAverage = reuseSamples == 0
                    ? spent
                    : reuseAverage + smoothing * (spent - reuseAverage)
                reuseSamples += 1
            }

            if index % 25 == 0 {
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                let toReuse = max(0, total - toCompute)
                // A population too small to move the total by much does not
                // need to be sampled before an estimate is shown -- its
                // average barely matters either way. Without this, a scan
                // right after the cache was invalidated (toReuse near zero,
                // everyone needs computing) waited on however many reused
                // photos happened to exist to show up in enumeration order,
                // which could be never before the last few percent of a
                // 180,000-photo pass.
                let negligible = max(20, total / 100)
                let sampled = (toCompute < negligible || computeSamples >= min(20, toCompute))
                    && (toReuse < negligible || reuseSamples >= min(20, toReuse))
                var remaining: TimeInterval?
                if sampled && elapsed >= 2 {
                    let computeLeft = max(0, toCompute - computeSamples)
                    let reuseLeft = max(0, toReuse - reuseSamples)
                    remaining = Double(computeLeft) * computeAverage
                        + Double(reuseLeft) * reuseAverage
                }
                progress(index + 1, total, remaining)
            }
        }
        // Every 25th photo is reported, so without this the bar stops at
        // 999 / 1000 and sits there for as long as the grouping takes.
        progress(total, total, nil)

        // An empty result is never allowed to overwrite the cache. A scan that
        // produced nothing -- no permission, or a library that answered with
        // nothing -- would otherwise throw away every fingerprint and make the
        // next full scan start from the beginning.
        //
        // Neither is a 選択した写真のみ run: the fetch there returns only the
        // photos the user picked, so three permitted photos would replace the
        // entire cache with three entries and the first full scan afterwards
        // would recompute the library for no reason anyone could see. The cache
        // only ever saves time, so the safe side is not to write it.
        if !limited && total > 0 && !prints.isEmpty { FingerprintCache.save(prints) }
        finished(ScanOutcome(prints: prints,
                             total: total,
                             reused: reused,
                             computed: computed,
                             missing: missing,
                             milliseconds: PhotoScanFormat.milliseconds(since: started),
                             memoryMB: Footprint.megabytes,
                             cacheSkipped: limited,
                             cacheInvalidated: loaded.invalidated))
    }

    private nonisolated static func fingerprint(
        of asset: PHAsset,
        manager: PHImageManager,
        options: PHImageRequestOptions,
        target: CGSize
    ) -> PhotoFingerprint? {
        let box = ThumbnailBox()
        let waiter = DispatchSemaphore(value: 0)
        manager.requestImage(for: asset,
                             targetSize: target,
                             contentMode: .aspectFit,
                             options: options) { image, _ in
            box.set(image?.cgImage)
            waiter.signal()
        }
        // A request that never answers must not stall the whole library. What
        // the timeout does not do is cancel the request, so the handler still
        // runs -- afterwards, on the Photos queue, while this thread has moved
        // on. A captured var would then be a strong reference written on one
        // thread and read on another, which is undefined behaviour and can
        // over-release; with iCloud originals and isNetworkAccessAllowed off,
        // the timeout is reached thousands of times in a single pass.
        _ = waiter.wait(timeout: .now() + 5)

        guard let thumbnail = box.take(),
              let coarse = ImageHash.coarse(of: thumbnail),
              let fine = ImageHash.fine(of: thumbnail),
              let colorHistogram = ImageHash.colorHistogram(of: thumbnail) else { return nil }

        // Real pixel dimensions, not the thumbnail's: aspectFit scales the
        // callback image to fit inside `target`, so only the asset's own
        // width/height describe the physical scale the row profile needs.
        let profiles = ImageHash.cropProfiles(of: thumbnail,
                                              realWidth: asset.pixelWidth,
                                              realHeight: asset.pixelHeight)

        return PhotoFingerprint(
            localIdentifier: asset.localIdentifier,
            coarse: coarse,
            fine: fine,
            colorHistogram: colorHistogram,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            burstIdentifier: asset.burstIdentifier,
            isFavorite: asset.isFavorite,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            colProfile: profiles?.columns,
            rowProfile: profiles?.rows
        )
    }
}

/// One image handed from the Photos callback to the thread waiting on it, under
/// a lock. Deliberately at file scope: nested in the @MainActor class above it
/// would inherit that isolation and be out of reach of the scan thread.
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
