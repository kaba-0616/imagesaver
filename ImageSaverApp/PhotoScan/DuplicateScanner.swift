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

    private static let queue = DispatchQueue(label: "jp.kaba.imagesaver.photoscan",
                                             qos: .userInitiated)

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
        regroup(note: "レベル変更")
    }

    func regroup(note: String) {
        forgetUndo()
        // Ahead of the early return, not after it. A grouping in flight belongs
        // to the list being replaced either way, and one that lands after the
        // list has been emptied puts already deleted photos back on screen.
        groupToken += 1

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
            return
        }

        let token = groupToken
        let snapshot = fingerprints
        let level = self.level
        let rejected = rejections.memberSets
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

        Self.queue.async {
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
            let result = DuplicateGrouper.group(snapshot,
                                                level: level,
                                                rejected: rejected,
                                                progress: progress)
            let elapsed = PhotoScanFormat.milliseconds(since: started)
            Task { @MainActor [weak self] in
                self?.apply(result, token: token, milliseconds: elapsed, note: note)
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
        switch await rejections.add(members) {
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
            regroup(note: "棄却の反映")
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
            regroup(note: "棄却の取り消し")
            return .listChanged
        }
        // A grouping that landed between the rejection and this press can have
        // brought the card back on its own. DuplicateGroup is Identifiable, so
        // inserting it a second time gives ForEach two rows with one id and the
        // rows stop matching the photos under them.
        guard !groups.contains(where: { $0.id == group.id }) else {
            log("棄却の取り消し: 同じ組が既に一覧に戻っていたため照合をやり直す")
            regroup(note: "棄却の取り消し")
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

    func clearRejections() async -> RejectOutcome {
        let before = rejections.count
        switch await rejections.removeAll() {
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
        log("棄却を全解除: \(before)組")
        regroup(note: "棄却の全解除")
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
        scanReport = "\(outcome.total)枚を走査 \(outcome.milliseconds)ms"
        if outcome.reused > 0 { scanReport += " (再利用\(outcome.reused)枚)" }
        log("走査完了: 対象\(outcome.total)枚 / 再利用\(outcome.reused)枚 / 新規\(outcome.computed)枚 / \(outcome.milliseconds)ms / メモリ\(outcome.memoryMB)MB")
        if outcome.missing > 0 {
            log("[!] サムネイルを取得できず指紋を作れなかった写真: \(outcome.missing)枚")
        }
        if outcome.cacheSkipped {
            log("[!] 指紋の保存を見送った: 権限が「選択した写真のみ」のため、見えている\(outcome.total)枚で全体を上書きしない (次回は再計算になる)")
        }
        PhotoScanLog.shared.flush()
        // Out of .scanning before the re-group, which refuses to run while a
        // scan is in flight. Both happen in one turn, so nothing is drawn in
        // between.
        phase = .grouping(fraction: 0, remaining: nil)
        regroup(note: "走査後の照合")
    }

    private func updateGrouping(fraction: Double, remaining: TimeInterval?, token: Int) {
        guard token == groupToken else { return }
        if case .grouping = phase {
            phase = .grouping(fraction: fraction, remaining: remaining)
        } else if regrouping != nil {
            regrouping = Regrouping(fraction: fraction, remaining: remaining)
        }
    }

    private func apply(_ result: [DuplicateGroup], token: Int, milliseconds: Int, note: String) {
        guard token == groupToken else { return }
        groups = result
        refreshGroupIndex()
        // The list held for the undo came out of the generation before this
        // one. Keeping it would let 取り消す splice a card from the old list
        // into the new one, where the same id can already be present.
        forgetUndo()
        regrouping = nil
        phase = .ready

        let identical = result.filter { $0.kind == .identical }
        let similar = result.filter { $0.kind == .similar }
        let identicalPhotos = identical.reduce(0) { $0 + $1.members.count }
        let similarPhotos = similar.reduce(0) { $0 + $1.members.count }
        let largest = result.map(\.members.count).max() ?? 0

        report = scanReport
            + " / 照合 \(milliseconds)ms"
            + " / 重複 \(identical.count)組 \(identicalPhotos)枚"
            + " / 類似 \(similar.count)組 \(similarPhotos)枚"
        reportMissingSizes(in: result, pending: true)
        log("照合(\(note)): レベル\(level) ハミング距離\(DuplicateLevel.distance(for: level)) / \(milliseconds)ms / 重複\(identical.count)組\(identicalPhotos)枚 / 類似\(similar.count)組\(similarPhotos)枚 / 最大の組\(largest)枚 / 棄却\(rejectionCount)組")

        loadDetails()
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
            guard members.count > 1 else {
                emptied += 1
                continue
            }
            kept.append(DuplicateGroup(id: group.id,
                                       kind: group.kind,
                                       members: members,
                                       hasRejectedPair: group.hasRejectedPair))
        }
        groups = kept
        refreshGroupIndex()
        forgetUndo()
        let identical = kept.filter { $0.kind == .identical }.count
        let similar = kept.filter { $0.kind == .similar }.count
        log("削除後の整理: \(Int(Date().timeIntervalSince(started) * 1000))ms"
            + " / 1枚だけになり消えた組 \(emptied)組"
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
        Self.queue.async {
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
                members = DuplicateGrouper.order(updated)
                if members.first?.localIdentifier != updated.first?.localIdentifier {
                    reordered += 1
                }
            }
            return DuplicateGroup(id: group.id,
                                  kind: group.kind,
                                  members: members,
                                  hasRejectedPair: group.hasRejectedPair)
        }
        refreshGroupIndex()
        reportMissingSizes(in: groups, pending: false)

        if changed { saveFingerprints() }
        let unknown = found.values.filter { $0.byteCount == nil }.count
        log("サイズ取得: \(found.count)枚 \(milliseconds)ms / 残す候補が変わった組 \(reordered)組 / 選択済みのため据え置き \(held)組"
            + (unknown > 0 ? " / 不明 \(unknown)枚" : ""))
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
        Self.queue.async { FingerprintCache.save(snapshot) }
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

        var cache = FingerprintCache.load()

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
                // Nothing is shown until both populations have been sampled
                // enough to be worth believing.
                let sampled = computeSamples >= min(20, toCompute)
                    && reuseSamples >= min(20, toReuse)
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
                             cacheSkipped: limited))
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
