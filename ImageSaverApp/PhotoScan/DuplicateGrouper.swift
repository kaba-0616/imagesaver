import Foundation

struct DuplicateGroup: Identifiable {

    enum Kind: String, Hashable, CaseIterable, Codable {
        case identical
        case similar

        var label: String {
            switch self {
            case .identical: return "同じ写真"
            case .similar: return "似ている写真"
            }
        }

        var tabLabel: String {
            switch self {
            case .identical: return "重複"
            case .similar: return "類似"
            }
        }

        /// The same on both tabs, because the ranking is the same on both
        /// tabs. Wording that names a rule the app no longer follows is worse
        /// than wording that says less.
        var selectAllLabel: String { "残す1枚を除いてすべて選択" }

        var emptyLabel: String {
            switch self {
            case .identical: return "同じ写真は見つかりませんでした"
            case .similar: return "似ている写真は見つかりませんでした"
            }
        }
    }

    let id: Int
    let kind: Kind
    /// Best first: the one worth keeping is members[0].
    let members: [PhotoFingerprint]
    /// True when some pair inside this group was once marked as different.
    /// The group is here anyway because a new photo joined it and reconnected
    /// the rest -- which is worth saying out loud, or it reads as the app
    /// having forgotten.
    let hasRejectedPair: Bool
    /// Members a crop-detection pass matched to a fuller version elsewhere in
    /// this group. Never empty and never everyone: something in the group is
    /// always the full frame, or there would be nothing to compare a crop
    /// against in the first place.
    let croppedIdentifiers: Set<String>

    var suggestedKeep: PhotoFingerprint { members[0] }
    var suggestedDelete: [PhotoFingerprint] { Array(members.dropFirst()) }

    /// Oldest first, for the strip and the fullscreen swipe order only.
    /// Deliberately separate from `members`: that array's position 0 is what
    /// `suggestedKeep`/`suggestedDelete` and the size-arrival reorder above key
    /// off, and this must never touch that regardless of what order the tiles
    /// are shown in.
    var displayOrder: [PhotoFingerprint] {
        members.sorted { DuplicateGrouper.timestamp($0) < DuplicateGrouper.timestamp($1) }
    }

    /// Reached only by deleting members out of a live group: a fresh group
    /// never starts this small. The card stays on screen instead of vanishing,
    /// so the one photo the user chose to keep stays visible as confirmation.
    var isCleanedUp: Bool { members.count <= 1 }

    /// nil unless every member size is known, so a partial total is never
    /// presented as the whole.
    var totalBytes: Int64? {
        var total: Int64 = 0
        for member in members {
            guard let bytes = member.byteCount else { return nil }
            total += bytes
        }
        return total > 0 ? total : nil
    }
}

/// The 0...10 the user sees, and the hamming distance the hash actually needs.
///
/// The two run in opposite directions: on the slider 10 is the strictest, on a
/// 64 bit dHash a bigger distance is the loosest. Passing one straight into the
/// other inverts the whole feature, so the conversion lives here alone and both
/// numbers are written into the log.
///
/// distance and level move 1-for-1 (0...10 both ways). It used to be 2-for-1,
/// covering hamming distance up to 20, but distances above 10 never found
/// real duplicates on a large library -- they just merged unrelated photos
/// into one enormous group -- so that half of the range was dropped and the
/// remaining one was given the slider's full 11 steps instead of sharing them.
enum DuplicateLevel {

    static let range = 0...10
    // Levels below here (old distance 12-20) were dropped: on a 182k photo
    // library they collapsed tens of thousands of unrelated photos into one
    // group instead of finding actual duplicates, and even the tightened
    // (build79/80) anchor+fine-hash guard only dented that, never fixed it.
    // The distance-8 default below (old level 6) is worth keeping regardless.
    static let standard = 2
    // Matches build 69 "標準" at hamming distance 8.

    private static let key = "photoScanLevel"

    static func clamp(_ level: Int) -> Int {
        min(max(level, range.lowerBound), range.upperBound)
    }

    static func distance(for level: Int) -> Int {
        range.upperBound - clamp(level)
    }

    static func stored() -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return standard }
        return clamp(UserDefaults.standard.integer(forKey: key))
    }

    static func store(_ level: Int) {
        UserDefaults.standard.set(clamp(level), forKey: key)
    }

    static func detail(for level: Int) -> String {
        switch clamp(level) {
        case 10: return "完全に同じ写真だけ"
        case 8, 9: return "ほぼ同じ写真だけ"
        case 6, 7: return "見比べて同じと思える程度"
        case 3, 4, 5: return "撮り直しや連写も拾う"
        default: return "少しでも似ていれば拾う"
        }
    }
}

enum DuplicateGrouper {

    /// Photographs of the same scene form a chain -- A resembles B, B
    /// resembles C -- so a group can grow past what any two members have in
    /// common. That is the behaviour wanted for a burst, and the reason the
    /// level is offered rather than fixed.
    ///
    /// A pure function on purpose. It runs on a background queue, so reaching
    /// for the rejection store from in here would be a data race; the
    /// decisions are handed in by value instead, and turning them into index
    /// pairs is this function own job because the indices belong to it.
    struct Result {
        let groups: [DuplicateGroup]
        /// The crop pass now runs on its own, so its own time is all of it --
        /// gates included, not just the sliding-window step. 0 when a cached
        /// result was reused instead of recomputed.
        let cropMS: Int
        /// How many pairs made it past the width bucket and the cheap gates to
        /// the actual sliding-window comparison. The number that says whether
        /// a slow crop pass is because one width bucket is enormous, or
        /// something else entirely.
        let cropCandidatePairs: Int
        /// The largest group of photos sharing one exact pixel width -- the
        /// number a slow crop pass is almost certainly explained by.
        let largestWidthBucket: Int
        /// Handed back so the caller can offer it to the next call. nil only
        /// when there was nothing to group in the first place.
        let cropCache: CropCache?
        /// True when `cropCache` was accepted as-is rather than recomputed --
        /// so a caller logging `cropMS` knows 0 means "skipped", not "instant".
        let cropReused: Bool
        /// Pairs that shared a coarse hash and an aspect ratio close enough to
        /// be worth a look, but were rejected on fine hash or colour
        /// histogram by a small enough margin to be worth showing to someone
        /// deciding whether a threshold is too tight -- never populated
        /// unless the caller asked via `collectNearMisses`, and never fed
        /// back into the matching decision itself. See `groupSimilar`.
        let nearMisses: [NearMissEntry]
    }

    /// One pair a diagnostic pass judged "close but no match" -- see
    /// `Result.nearMisses`. Exists so a caller can see what a real photo that
    /// should have matched but didn't looks like (a low-quality web copy next
    /// to its original, say) without that pair ever showing up in the actual
    /// results, which the surviving-groups view alone cannot show.
    struct NearMissEntry {
        let idA: String
        let idB: String
        let fineDistance: Int
        let fineThreshold: Int
        let histogramDiff: Double
        let histogramThreshold: Double
        let widthA: Int
        let heightA: Int
        let widthB: Int
        let heightB: Int
        let byteCountA: Int64?
        let byteCountB: Int64?
    }

    /// What one crop pass found, kept in a form cheap enough to replay: the
    /// index pairs it decided to union, not the profiles that led there.
    /// Crop detection does not depend on `level`, so a caller whose only
    /// change since the last grouping was the slider can hand this back
    /// in and skip the pass entirely -- the pairs mean the same thing again
    /// as long as the snapshot they were computed against has not changed.
    struct CropCache {
        let matchedPairs: [(Int, Int)]
        let cropped: Set<Int>
        let candidatePairs: Int
        let largestBucket: Int
    }

    /// Groups sharing an exact fine-hash+dimensions+byte-size key or a burst
    /// id, and nothing else -- no hamming threshold, no crop pass. This is
    /// what `.identical` membership has always actually reduced to (see
    /// `kind(of:)`), so it costs an O(n) pass over the library instead of the
    /// O(n²) comparison `groupSimilar` needs -- independent of `level`
    /// entirely, and fast enough to redo on its own without dragging the
    /// similar tab's expensive pass along with it.
    static func groupIdentical(_ prints: [PhotoFingerprint], rejected: [Set<String>]) -> [DuplicateGroup] {
        guard prints.count > 1 else { return [] }
        let indexByID = buildIndexByID(prints)
        let (rejectedPairs, rejectedIndices) = expandRejections(rejected, indexByID: indexByID)
        var sets = DisjointSet(prints.count)
        linkExactAndBursts(prints, into: &sets, rejectedPairs: rejectedPairs, rejectedIndices: rejectedIndices)
        return buildGroups(prints, in: &sets, onlyKind: .identical,
                           hasRejections: !rejectedPairs.isEmpty,
                           rejectedPairs: rejectedPairs, rejectedIndices: rejectedIndices,
                           croppedIndices: [])
    }

    static func groupSimilar(_ prints: [PhotoFingerprint],
                             level: Int,
                             rejected: [Set<String>],
                             cropCache: CropCache? = nil,
                             cropTimeShare: Double = 0.8,
                             collectNearMisses: Bool = false,
                             progress: (@Sendable (Double) -> Void)? = nil) -> Result {
        guard prints.count > 1 else {
            return Result(groups: [], cropMS: 0, cropCandidatePairs: 0, largestWidthBucket: 0,
                         cropCache: nil, cropReused: false, nearMisses: [])
        }
        let count = prints.count

        let indexByID = buildIndexByID(prints)
        let (rejectedPairs, rejectedIndices) = expandRejections(rejected, indexByID: indexByID)
        var sets = DisjointSet(count)
        linkExactAndBursts(prints, into: &sets, rejectedPairs: rejectedPairs, rejectedIndices: rejectedIndices)

        // Flat arrays: the inner loop runs tens of millions of times and
        // reaching through a struct for each field is most of the cost.
        let coarse = prints.map(\.coarse)
        let aspects = prints.map(\.aspect)
        let threshold = DuplicateLevel.distance(for: level)
        // The 64-bit coarse hash is an 8x8 grid -- coarse enough that on a
        // large library, unrelated photos land within a loose threshold of
        // each other by chance (confirmed on device: level 0, threshold 20,
        // put 182187 of 182300 photos in one group). The fine hash (512 bits,
        // a 32x16 grid -- see `ImageHash.fine`) is meant to be the hash that
        // can actually tell two different photographs apart, so its threshold
        // is scaled by 8 (512/64 bits) to keep the same relative looseness
        // per level. A provisional multiplier pending a real-device retest,
        // same as the crop thresholds below -- and see `histogramThreshold`
        // for the gate added after even 256 bits at distance 0 still let a
        // 33-photo group of unrelated pictures through.
        // Multiplier raised from 8 (build92) to 20 (build93) to 25 (build94):
        // at level 0 (threshold 10) the original formula gave
        // fineThreshold=80/512, tight enough to miss a photo genuinely
        // re-encoded elsewhere -- a low-quality copy pulled off a website
        // next to the original, say, where the smaller copy's fine detail is
        // really gone, not just differently compressed. Real-device near-miss
        // data from build93 (run #53) showed every rejected pair was already
        // well inside build93's fineThreshold=200 and was failing on
        // histogramThreshold instead, so 25 (level 0 = 250) is not chasing a
        // fine-hash problem anymore -- it is the level-0 target value fixed
        // by the user directly, with headroom above what real near-misses
        // needed. The other three gates (coarse hash, aspect ratio, colour
        // histogram) still apply unchanged, so widening this one does not
        // hand back the 182k-photo runaway that widening thresholds broadly
        // once did.
        let fineThreshold = min(threshold * 25, 512)
        let histoThreshold = histogramThreshold(for: threshold)
        let hasRejections = !rejectedPairs.isEmpty
        // The work is a triangle, so i/n would claim half done a quarter of the
        // way through. Pairs are what actually gets done.
        let totalPairs = count * (count - 1) / 2

        // The crop pass costs far more per pair than this loop does -- a
        // coarse hash compare here is a XOR and a popcount, while a crop
        // candidate walks whole profiles -- so a fair split of the gauge
        // between the two cannot come from comparing pair counts. It comes
        // from the caller's own memory of how the last real pass on this
        // library actually split, which is what `cropTimeShare` is.
        let mainWeight = 1 - min(max(cropTimeShare, 0.05), 0.95)

        // Chaining guard: without this, a match is transitive by construction
        // (A-B close, B-C close => A, B, C one group) even when A and C do not
        // look alike at all. On a loose enough threshold and a large enough
        // library this snowballs -- at level 0 on a 182k-photo library the
        // whole library chained into one group of 182187.
        //
        // An earlier version of this guard checked each new member against
        // only the group's first photo (its "anchor"), which stopped that
        // runaway case but left its own gap: two members could each match the
        // anchor while not matching each other, and nothing here ever
        // compared them directly. A real 182,000-photo library found exactly
        // that gap -- a 33-photo group at fine-hash distance 0, sharing no
        // burst id, spanning years, with unrelated file sizes -- so the check
        // below is now a full clique requirement: two groups are only ever
        // merged once every existing member of one has been checked against
        // every existing member of the other. `DisjointSet.groupMembers`
        // makes that list available without an extra scan; the cost lands
        // once, per merge, as `|groupI| x |groupJ|`, not on every future
        // lookup the way scanning `parent` for it would.
        var nearMisses: [NearMissEntry] = []
        for i in 0..<count {
            if let progress, i % 256 == 0, totalPairs > 0 {
                let donePairs = i * (2 * count - i - 1) / 2
                progress(Double(donePairs) / Double(totalPairs) * mainWeight)
            }
            for j in (i + 1)..<count {
                if collectNearMisses, nearMisses.count < 5000,
                   let miss = nearMissDetail(i, j, prints: prints, coarse: coarse, aspects: aspects,
                                             threshold: threshold, fineThreshold: fineThreshold,
                                             histogramThreshold: histoThreshold) {
                    nearMisses.append(miss)
                }
                guard isCandidateMatch(i, j, prints: prints, coarse: coarse, aspects: aspects,
                                       threshold: threshold, fineThreshold: fineThreshold,
                                       histogramThreshold: histoThreshold) else { continue }
                if hasRejections && rejectedPairs.contains(pairKey(i, j)) { continue }

                let rootI = sets.find(i), rootJ = sets.find(j)
                if rootI != rootJ {
                    let groupI = sets.groupMembers(ofRoot: rootI)
                    let groupJ = sets.groupMembers(ofRoot: rootJ)
                    var allMatch = true
                    outer: for a in groupI {
                        for b in groupJ {
                            if a == i && b == j { continue } // already checked above
                            guard isCandidateMatch(a, b, prints: prints, coarse: coarse, aspects: aspects,
                                                   threshold: threshold, fineThreshold: fineThreshold,
                                                   histogramThreshold: histoThreshold) else {
                                allMatch = false
                                break outer
                            }
                        }
                    }
                    guard allMatch else { continue }
                }
                sets.union(i, j)
            }
        }
        progress?(mainWeight)

        // Crop detection is a separate pass, not fused into the loop above.
        // It used to be, gated per-pair on width alone -- but a real camera
        // roll concentrates tens of thousands of photos onto a handful of
        // resolutions, so that gate let hundreds of millions of pairs through
        // to the profile comparison before the O(n²) similarity loop even
        // finished its first slice. Bucketing by width first means only
        // same-width pairs are ever looked at, which is the same set of pairs
        // the old gate eventually reached anyway -- just found in a sum of
        // small squares instead of one enormous one.
        let cropOutcome: CropOutcome
        if let cropCache {
            // level is not one of the inputs a crop pass looks at, so a caller
            // that only changed the slider since the last grouping already
            // knows the answer -- replaying the union calls costs nothing
            // next to redoing the profile comparisons that found them.
            for (a, b) in cropCache.matchedPairs { sets.union(a, b) }
            cropOutcome = CropOutcome(cropped: cropCache.cropped, milliseconds: 0,
                                      candidatePairs: cropCache.candidatePairs,
                                      largestBucket: cropCache.largestBucket,
                                      matchedPairs: cropCache.matchedPairs)
            progress?(1)
        } else {
            let cropProgress: (@Sendable (Double) -> Void)? = progress.map { report in
                { (local: Double) in report(mainWeight + local * (1 - mainWeight)) }
            }
            cropOutcome = cropMatches(prints, in: &sets,
                                      rejectedPairs: rejectedPairs,
                                      hasRejections: hasRejections,
                                      progress: cropProgress)
            progress?(1)
        }
        let sorted = buildGroups(prints, in: &sets, onlyKind: .similar,
                                 hasRejections: hasRejections,
                                 rejectedPairs: rejectedPairs, rejectedIndices: rejectedIndices,
                                 croppedIndices: cropOutcome.cropped)
        return Result(groups: sorted,
                     cropMS: cropOutcome.milliseconds,
                     cropCandidatePairs: cropOutcome.candidatePairs,
                     largestWidthBucket: cropOutcome.largestBucket,
                     cropCache: DuplicateGrouper.CropCache(matchedPairs: cropOutcome.matchedPairs,
                                                           cropped: cropOutcome.cropped,
                                                           candidatePairs: cropOutcome.candidatePairs,
                                                           largestBucket: cropOutcome.largestBucket),
                     cropReused: cropCache != nil,
                     nearMisses: nearMisses
                        .sorted { ($0.fineDistance - $0.fineThreshold) < ($1.fineDistance - $1.fineThreshold) }
                        .prefix(20)
                        .map { $0 })
    }

    /// Diagnostic only -- never called from the matching path that decides a
    /// group, so widening what counts as "close" here can never change what
    /// counts as a duplicate. Answers a question the surviving-groups view
    /// cannot: how near did a pair that did NOT match get to the threshold,
    /// and on which gate.
    private static func nearMissDetail(_ i: Int, _ j: Int,
                                       prints: [PhotoFingerprint],
                                       coarse: [UInt64],
                                       aspects: [Double],
                                       threshold: Int,
                                       fineThreshold: Int,
                                       histogramThreshold: Double) -> NearMissEntry? {
        guard (coarse[i] ^ coarse[j]).nonzeroBitCount <= threshold else { return nil }
        let ratio = aspects[i] / aspects[j]
        guard ratio >= 0.88 && ratio <= 1.14 else { return nil }
        let fineDistance = prints[i].fine.distance(to: prints[j].fine)
        let histoDiff = meanAbsDifference(prints[i].colorHistogram, prints[j].colorHistogram)
        let failedFine = fineDistance > fineThreshold
        let failedHisto = histoDiff > histogramThreshold
        guard failedFine || failedHisto else { return nil }
        // "Close" enough to be worth a line in the log -- otherwise every
        // unrelated pair sharing a coarse-hash bucket would flood it.
        guard fineDistance <= fineThreshold + 400 || histoDiff <= histogramThreshold + 30 else { return nil }
        return NearMissEntry(idA: prints[i].localIdentifier, idB: prints[j].localIdentifier,
                             fineDistance: fineDistance, fineThreshold: fineThreshold,
                             histogramDiff: histoDiff, histogramThreshold: histogramThreshold,
                             widthA: prints[i].width, heightA: prints[i].height,
                             widthB: prints[j].width, heightB: prints[j].height,
                             byteCountA: prints[i].byteCount, byteCountB: prints[j].byteCount)
    }

    /// Every gate a pair has to pass to be considered the same picture:
    /// coarse hash, aspect ratio, fine hash, and colour histogram. Used both
    /// for a single (i, j) check and, inside the clique guard above, for
    /// every pair between two candidate groups -- one place to keep all four
    /// conditions in sync rather than two copies drifting apart.
    private static func isCandidateMatch(_ i: Int, _ j: Int,
                                         prints: [PhotoFingerprint],
                                         coarse: [UInt64],
                                         aspects: [Double],
                                         threshold: Int,
                                         fineThreshold: Int,
                                         histogramThreshold: Double) -> Bool {
        guard (coarse[i] ^ coarse[j]).nonzeroBitCount <= threshold else { return false }
        // A portrait and a landscape squashed onto the same grid can score
        // alike without looking alike. Written as a positive test so a NaN --
        // either side missing its pixel size -- fails it rather than slipping
        // through two negative ones.
        let ratio = aspects[i] / aspects[j]
        guard ratio >= 0.88 && ratio <= 1.14 else { return false }
        guard prints[i].fine.distance(to: prints[j].fine) <= fineThreshold else { return false }
        guard meanAbsDifference(prints[i].colorHistogram, prints[j].colorHistogram) <= histogramThreshold else { return false }
        return true
    }

    /// Mean absolute per-bin difference (0...255) above which two photos'
    /// colour palettes are different enough that a close coarse/fine hash
    /// must not be allowed to override it -- the gate added after a real
    /// device still showed unrelated photographs colliding at fine-hash
    /// distance 0. Loosely widened with `threshold` for the same reason
    /// `fineThreshold` is: a looser level should tolerate a somewhat bigger
    /// colour mismatch, not none at all. A value to retune from a real
    /// library, same as every other gate in this file.
    // build93's near-miss diagnostics (real device, run #53) found this was
    // the actual bottleneck once fineThreshold was widened: every pair the
    // user's website-quality-copy case would need was already well inside
    // the fine-hash gate, but fell 0.1-1.3 short of build93's 30.0 at level
    // 0. Coefficients raised (build94) so level 0 lands exactly on the 40 cap.
    private static func histogramThreshold(for threshold: Int) -> Double {
        min(10.0 + Double(threshold) * 3.0, 40)
    }

    // MARK: - Shared setup

    private static func buildIndexByID(_ prints: [PhotoFingerprint]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(prints.count)
        for (index, print) in prints.enumerated() {
            result[print.localIdentifier] = index
        }
        return result
    }

    /// Identifier sets in, packed index pairs out. The inner loops both
    /// `groupIdentical` and `groupSimilar` run afterward cannot afford to
    /// look anything up by string, so the rejection decisions are converted
    /// to index pairs once, here.
    private static func expandRejections(_ rejected: [Set<String>],
                                         indexByID: [String: Int]) -> (pairs: Set<Int64>, indices: Set<Int>) {
        var rejectedPairs = Set<Int64>()
        var rejectedIndices = Set<Int>()
        for decision in rejected {
            var members: [Int] = []
            members.reserveCapacity(decision.count)
            for identifier in decision {
                if let index = indexByID[identifier] { members.append(index) }
            }
            guard members.count > 1 else { continue }
            for a in 0..<(members.count - 1) {
                for b in (a + 1)..<members.count {
                    rejectedPairs.insert(pairKey(members[a], members[b]))
                }
            }
            for index in members { rejectedIndices.insert(index) }
        }
        return (rejectedPairs, rejectedIndices)
    }

    private static func linkExactAndBursts(_ prints: [PhotoFingerprint],
                                           into sets: inout DisjointSet,
                                           rejectedPairs: Set<Int64>,
                                           rejectedIndices: Set<Int>) {
        // Same picture, byte-for-byte or near enough that 256 bits cannot tell
        // them apart. Found by lookup rather than comparison, so it costs
        // nothing even on a large library.
        var byExact: [ExactKey: [Int]] = [:]
        byExact.reserveCapacity(prints.count)
        for (index, print) in prints.enumerated() {
            byExact[ExactKey(print), default: []].append(index)
        }
        for (_, members) in byExact {
            link(members, in: &sets,
                 rejectedPairs: rejectedPairs, rejectedIndices: rejectedIndices)
        }

        // A burst is a group the camera already decided on.
        var byBurst: [String: [Int]] = [:]
        for (index, print) in prints.enumerated() {
            guard let burst = print.burstIdentifier else { continue }
            byBurst[burst, default: []].append(index)
        }
        for (_, members) in byBurst {
            link(members, in: &sets,
                 rejectedPairs: rejectedPairs, rejectedIndices: rejectedIndices)
        }
    }

    /// Turns the disjoint set into groups, keeping only the ones whose kind
    /// (by `kind(of:)`, decided by the members alone) matches `onlyKind` --
    /// this is what lets `groupIdentical` and `groupSimilar` share one
    /// union-find walk and one sort while each returning only its own tab's
    /// half of it.
    private static func buildGroups(_ prints: [PhotoFingerprint],
                                    in sets: inout DisjointSet,
                                    onlyKind: DuplicateGroup.Kind,
                                    hasRejections: Bool,
                                    rejectedPairs: Set<Int64>,
                                    rejectedIndices: Set<Int>,
                                    croppedIndices: Set<Int>) -> [DuplicateGroup] {
        var buckets: [Int: [Int]] = [:]
        for index in 0..<prints.count {
            buckets[sets.find(index), default: []].append(index)
        }

        var groups: [DuplicateGroup] = []
        for (root, indices) in buckets where indices.count > 1 {
            let members = indices.map { prints[$0] }
            guard kind(of: members) == onlyKind else { continue }
            let flagged = hasRejections
                && containsRejectedPair(indices, in: rejectedPairs, touching: rejectedIndices)
            var cropped: Set<String> = []
            for index in indices where croppedIndices.contains(index) {
                cropped.insert(prints[index].localIdentifier)
            }
            groups.append(DuplicateGroup(id: root,
                                         kind: onlyKind,
                                         members: order(members, croppedIdentifiers: cropped),
                                         hasRejectedPair: flagged,
                                         croppedIdentifiers: cropped))
        }

        // Oldest photo first: the group holding the library's oldest memory
        // leads, not the group with the most members in it. Ties fall back to
        // the old rule (biggest group, then id) since a missing date should
        // not make two otherwise-equal groups swap places for no visible
        // reason.
        return groups.sorted { lhs, rhs in
            let left = oldest(lhs), right = oldest(rhs)
            if left != right { return left < right }
            if lhs.members.count != rhs.members.count {
                return lhs.members.count > rhs.members.count
            }
            return lhs.id < rhs.id
        }
    }

    /// The oldest `creationDate` among a group's members, in the same
    /// nil-sorts-last convention as `timestamp(_:)` below.
    private static func oldest(_ group: DuplicateGroup) -> TimeInterval {
        group.members.map(timestamp).min() ?? .greatestFiniteMagnitude
    }

    static func kind(of members: [PhotoFingerprint]) -> DuplicateGroup.Kind {
        guard let first = members.first else { return .similar }
        let key = ExactKey(first)
        return members.allSatisfy { ExactKey($0) == key } ? .identical : .similar
    }

    /// Best first, by one rule for both tabs: most pixels, then the biggest
    /// file, then the oldest. Exposed so the list can be put back in order
    /// once the file sizes arrive, rather than have the order shift silently
    /// under the user one tile at a time.
    ///
    /// A photo a crop-detection pass matched to a fuller version always sorts
    /// after every uncropped member, pixel count and file size notwithstanding
    /// -- a bigger file that is missing the top of the picture is still
    /// missing the top of the picture.
    static func order(_ members: [PhotoFingerprint], croppedIdentifiers: Set<String> = []) -> [PhotoFingerprint] {
        let bySize = sizesKnown(members) ? bestFirstWithSize : bestFirstWithoutSize
        guard !croppedIdentifiers.isEmpty else { return members.sorted(by: bySize) }
        return members.sorted { lhs, rhs in
            let lhsCropped = croppedIdentifiers.contains(lhs.localIdentifier)
            let rhsCropped = croppedIdentifiers.contains(rhs.localIdentifier)
            if lhsCropped != rhsCropped { return !lhsCropped }
            return bySize(lhs, rhs)
        }
    }

    /// All or nothing: mixing "by size" and "without size" inside one group is
    /// not a consistent ordering, and an inconsistent comparison is a sorting
    /// bug waiting to happen. Exposed because whoever writes the log has to
    /// say which of the two orderings was actually used.
    static func sizesKnown(_ members: [PhotoFingerprint]) -> Bool {
        members.allSatisfy { ($0.byteCount ?? 0) > 0 }
    }

    // MARK: - Crop detection

    /// A vertical-only crop keeps the original width; anything further off is
    /// almost certainly two different photos that happen to be a similar size.
    private static let cropMinHeightDrop = 0.05
    /// Mean absolute difference between two 32-sample column profiles
    /// (0...255 per sample) below which a pair is worth the sliding-window
    /// check. The first cut (18) turned out wide enough that a real
    /// 180,000-photo library produced a single "similar" group of 559
    /// visibly unrelated photos at level 10 -- chained together through
    /// crop matches, which do not look at level at all. Tightened hard;
    /// still a value to keep adjusting from real libraries, not a derived
    /// constant.
    private static let cropColumnGate: Double = 8
    /// How well the shorter photo's row profile has to fit somewhere inside
    /// the taller one's, 0 (nothing alike) to 1 (identical). Same caveat and
    /// same reason for moving it: 0.9 was loose enough to let the chain above
    /// through.
    private static let cropRowMatch: Double = 0.96
    /// Below this, a stretch of the image is close enough to a flat colour
    /// that almost anything would "fit" it -- sky, a wall, a stage
    /// background. Refusing to call a crop against a window this uniform is
    /// what keeps that from costing someone the full-frame photo instead of
    /// the cut one. Raised alongside the two gates above for the same reason.
    private static let cropMinVariance: Double = 200
    /// Fine-hash (512-bit) distance above which a pair is rejected even if
    /// every profile/variance check above passed. None of the checks above
    /// look at pixel content at all -- only column/row brightness profiles
    /// and how flat a window is -- so two different photos in front of the
    /// same stage backdrop or plain wall can satisfy all of them. A real
    /// 180,000-photo library found exactly that: a 33-photo group, fully
    /// closed by the full-clique guard below, whose fine-hash distances were
    /// still min 112 / avg 244.5 / max 320 out of 512 -- essentially the
    /// ~256 two unrelated photos land at by chance, not what a genuine crop
    /// of the same photo should show. 220 sits just under that random floor,
    /// meant to reject only pairs indistinguishable from unrelated photos
    /// while leaving real crops (which shift framing but still hash closer
    /// to their source than chance) through. No real "true crop pair" fine
    /// hash distance has been measured yet, so this is a starting point to
    /// retune once one has, not a derived constant.
    private static let cropFineHashGate = 220

    struct CropOutcome {
        let cropped: Set<Int>
        let milliseconds: Int
        let candidatePairs: Int
        let largestBucket: Int
        /// Every pair actually unioned, so a cache built from this can replay
        /// the decision without redoing the profile comparison that made it.
        let matchedPairs: [(Int, Int)]
    }

    /// Bucketed by exact pixel width first, so only same-width pairs are ever
    /// compared. A camera roll concentrates tens of thousands of photos onto a
    /// handful of resolutions; checking width per-pair inside the main O(n²)
    /// loop (the first cut of this feature) still paid for every pair in the
    /// largest such cluster before ever rejecting one, which is where a
    /// 180,000-photo library's crop pass stopped making visible progress.
    ///
    /// Widths within the old 2% tolerance are no longer merged across
    /// buckets: a tool that also resizes on crop would be missed here. Trading
    /// that away is what makes bucketing possible at all -- revisit only if a
    /// real library shows it costing real matches.
    private static func cropMatches(_ prints: [PhotoFingerprint],
                                    in sets: inout DisjointSet,
                                    rejectedPairs: Set<Int64>,
                                    hasRejections: Bool,
                                    progress: (@Sendable (Double) -> Void)? = nil) -> CropOutcome {
        let started = CFAbsoluteTimeGetCurrent()
        var widthBuckets: [Int: [Int]] = [:]
        for (index, print) in prints.enumerated() where print.width > 0 {
            widthBuckets[print.width, default: []].append(index)
        }

        // Known before a single pair is looked at, from bucket sizes alone --
        // so progress through this pass can be reported from the start
        // instead of only once it is already most of the way done.
        var totalVisits = 0
        var largestBucket = 0
        for (_, indices) in widthBuckets where indices.count > 1 {
            let n = indices.count
            totalVisits += n * (n - 1) / 2
            largestBucket = max(largestBucket, n)
        }

        var cropped = Set<Int>()
        var matchedPairs: [(Int, Int)] = []
        var candidatePairs = 0
        var visited = 0

        for (_, indices) in widthBuckets where indices.count > 1 {
            for a in 0..<(indices.count - 1) {
                let i = indices[a]
                let ha = prints[i].height
                for b in (a + 1)..<indices.count {
                    visited += 1
                    if let progress, visited % 8192 == 0, totalVisits > 0 {
                        progress(Double(visited) / Double(totalVisits))
                    }
                    let j = indices[b]
                    let hb = prints[j].height
                    guard ha != hb else { continue }
                    let shorter = min(ha, hb), taller = max(ha, hb)
                    guard Double(shorter) <= Double(taller) * (1 - cropMinHeightDrop) else { continue }
                    guard let colA = prints[i].colProfile, let colB = prints[j].colProfile,
                          meanAbsDifference(colA, colB) <= cropColumnGate else { continue }
                    guard let rowA = prints[ha > hb ? i : j].rowProfile,
                          let rowB = prints[ha > hb ? j : i].rowProfile else { continue }
                    if hasRejections && rejectedPairs.contains(pairKey(i, j)) { continue }

                    candidatePairs += 1
                    guard let match = bestCropOffset(full: rowA, crop: rowB),
                          match.score >= cropRowMatch else { continue }
                    // subdata(in:) indexes from rowA's own startIndex, not
                    // necessarily 0 -- offset is a count from the front either way.
                    let base = rowA.startIndex + match.offset
                    let window = rowA.subdata(in: base..<(base + rowB.count))
                    guard variance(of: window) >= cropMinVariance else { continue }
                    guard prints[i].fine.distance(to: prints[j].fine) <= cropFineHashGate else { continue }

                    // Chaining guard, the same idea as groupSimilar's own full
                    // clique check on the hamming-distance loop above: without
                    // it, a run of successive near-miss crop matches (same
                    // wall, same framing, different people entirely) merges
                    // transitively -- each photo only ever had to look like
                    // its one neighbour in the chain, never like the group as
                    // a whole. An anchor-only version of this guard (checking
                    // `j` against only the group's founding photo) cut a real
                    // 180k-photo library's runaway group from 559 to 52, then
                    // to 33 after cropColumnGate/cropRowMatch/cropMinVariance
                    // were tightened further -- it never closed the gap,
                    // because two non-anchor members could each crop-match
                    // the anchor without crop-matching each other. Requiring
                    // every existing member of `i`'s group to crop-match `j`
                    // is the same full clique requirement `groupSimilar`
                    // already uses for its own chaining guard.
                    let rootI = sets.find(i)
                    if rootI != i {
                        let groupMembers = sets.groupMembers(ofRoot: rootI)
                        guard groupMembers.allSatisfy({ $0 == i || cropMatch(prints[$0], prints[j]) }) else { continue }
                    }

                    sets.union(i, j)
                    matchedPairs.append((i, j))
                    cropped.insert(ha > hb ? j : i)
                }
            }
        }
        progress?(1)

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        return CropOutcome(cropped: cropped, milliseconds: elapsed,
                           candidatePairs: candidatePairs, largestBucket: largestBucket,
                           matchedPairs: matchedPairs)
    }

    /// The same vertical-crop test the main loop above applies to a bucketed
    /// pair, pulled out so the anchor guard can apply it to a pair that never
    /// shared a width bucket in the first place -- the anchor and `j` can
    /// come from different width buckets entirely once the anchor's own group
    /// already spans more than one.
    private static func cropMatch(_ a: PhotoFingerprint, _ b: PhotoFingerprint) -> Bool {
        let ha = a.height, hb = b.height
        guard ha != hb else { return false }
        let shorter = min(ha, hb), taller = max(ha, hb)
        guard Double(shorter) <= Double(taller) * (1 - cropMinHeightDrop) else { return false }
        guard let colA = a.colProfile, let colB = b.colProfile,
              meanAbsDifference(colA, colB) <= cropColumnGate else { return false }
        guard let rowA = (ha > hb ? a : b).rowProfile,
              let rowB = (ha > hb ? b : a).rowProfile,
              let match = bestCropOffset(full: rowA, crop: rowB), match.score >= cropRowMatch else { return false }
        let base = rowA.startIndex + match.offset
        let window = rowA.subdata(in: base..<(base + rowB.count))
        guard variance(of: window) >= cropMinVariance else { return false }
        return a.fine.distance(to: b.fine) <= cropFineHashGate
    }

    /// `static` rather than `private`: the largest-group diagnostic log in
    /// `DuplicateScanner` reuses this exact distance so its numbers describe
    /// the same colour gap the matching gate above actually checks against,
    /// instead of a second, silently-drifting implementation.
    static func meanAbsDifference(_ a: Data, _ b: Data) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0
        for index in 0..<a.count {
            total += abs(Int(a[a.startIndex + index]) - Int(b[b.startIndex + index]))
        }
        return Double(total) / Double(a.count)
    }

    /// Slides `crop`'s profile along `full`'s looking for the best fit.
    /// `full` must not be shorter than `crop`, which the caller already knows
    /// from having picked the taller photo as `full`.
    private static func bestCropOffset(full: Data, crop: Data) -> (offset: Int, score: Double)? {
        guard crop.count <= full.count, !crop.isEmpty else { return nil }
        let fullBytes = [UInt8](full)
        let cropBytes = [UInt8](crop)
        let span = fullBytes.count - cropBytes.count
        var best: (offset: Int, score: Double)?
        for offset in 0...span {
            var total = 0
            for k in 0..<cropBytes.count {
                total += abs(Int(fullBytes[offset + k]) - Int(cropBytes[k]))
            }
            let score = 1 - (Double(total) / Double(cropBytes.count) / 255)
            if best == nil || score > best!.score { best = (offset, score) }
        }
        return best
    }

    private static func variance(of data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        let values = data.map { Double($0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let squared = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return squared / Double(values.count)
    }

    // MARK: - Linking

    /// Members that share an exact key or a burst id are all one group.
    ///
    /// Chaining from the first member is enough to connect them -- until a
    /// rejection removes one of those edges, at which point two members that
    /// were only ever connected through the first one fall apart. So the
    /// shortcut is kept for the common case and dropped only for the groups
    /// that actually carry a rejection, which are few and small.
    private static func link(_ members: [Int],
                             in sets: inout DisjointSet,
                             rejectedPairs: Set<Int64>,
                             rejectedIndices: Set<Int>) {
        guard members.count > 1 else { return }

        let touched = !rejectedIndices.isEmpty
            && members.contains(where: { rejectedIndices.contains($0) })
        if !touched {
            for offset in 1..<members.count { sets.union(members[0], members[offset]) }
            return
        }

        for a in 0..<(members.count - 1) {
            for b in (a + 1)..<members.count {
                if rejectedPairs.contains(pairKey(members[a], members[b])) { continue }
                sets.union(members[a], members[b])
            }
        }
    }

    /// Quadratic, so it is only ever run over the members that appear in some
    /// decision at all. On a library with a handful of rejections that leaves
    /// nothing to do for almost every group, and a group of 200 photos is
    /// 20000 pairs that would otherwise be walked for nothing.
    private static func containsRejectedPair(_ indices: [Int],
                                             in rejectedPairs: Set<Int64>,
                                             touching rejectedIndices: Set<Int>) -> Bool {
        guard indices.count > 1 else { return false }
        let candidates = indices.filter { rejectedIndices.contains($0) }
        guard candidates.count > 1 else { return false }
        for a in 0..<(candidates.count - 1) {
            for b in (a + 1)..<candidates.count {
                if rejectedPairs.contains(pairKey(candidates[a], candidates[b])) { return true }
            }
        }
        return false
    }

    /// Two indices in one integer, smaller in the high half so a pair has
    /// exactly one representation.
    private static func pairKey(_ lhs: Int, _ rhs: Int) -> Int64 {
        let low = Int64(min(lhs, rhs))
        let high = Int64(max(lhs, rhs))
        return (low << 32) | high
    }

    // MARK: - Ordering

    /// Most pixels, then the biggest file, then the oldest.
    ///
    /// The pixel count is the product, not the two sides compared in turn: the
    /// product does not change when EXIF orientation swaps width and height,
    /// so the ranking comes out the same either way.
    ///
    /// A favourite is not preferred here. The bulk action refuses to tick one
    /// for deletion, which is where favourites are protected; letting them
    /// jump the ranking as well would put a small favourite forward as 残す候補
    /// over a larger copy of the same picture.
    private static func bestFirstWithSize(_ lhs: PhotoFingerprint, _ rhs: PhotoFingerprint) -> Bool {
        if lhs.pixels != rhs.pixels { return lhs.pixels > rhs.pixels }
        let leftBytes = lhs.byteCount ?? 0, rightBytes = rhs.byteCount ?? 0
        if leftBytes != rightBytes { return leftBytes > rightBytes }
        let left = timestamp(lhs), right = timestamp(rhs)
        if left != right { return left < right }
        return lhs.localIdentifier < rhs.localIdentifier
    }

    /// The same rule with the file size step left out, for a group where at
    /// least one size could not be read.
    private static func bestFirstWithoutSize(_ lhs: PhotoFingerprint, _ rhs: PhotoFingerprint) -> Bool {
        if lhs.pixels != rhs.pixels { return lhs.pixels > rhs.pixels }
        let left = timestamp(lhs), right = timestamp(rhs)
        if left != right { return left < right }
        return lhs.localIdentifier < rhs.localIdentifier
    }

    /// A missing date sorts last and, more importantly, compares like every
    /// other value: falling through to a different field when one side is nil
    /// can make the comparison intransitive, which sorted(by:) is entitled to
    /// react badly to.
    /// `fileprivate` rather than `private`: `DuplicateGroup.displayOrder` above
    /// needs the same nil-sorts-last convention `oldest(_:)` already uses.
    fileprivate static func timestamp(_ print: PhotoFingerprint) -> TimeInterval {
        print.creationDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
    }

    private struct ExactKey: Hashable {
        let fine: FineHash
        let width: Int
        let height: Int
        /// Nil until the size fetch resolves it, so the very first pass right
        /// after a scan still groups on hash+dimensions alone -- two photos
        /// both still unknown are treated as a tentative match, the same as
        /// before this field existed. Once `applyDetails` fills it in for a
        /// group's members, `groupIdentical` is re-run and a pair that turns
        /// out to differ in size splits apart under the new key.
        let byteCount: Int64?

        init(_ print: PhotoFingerprint) {
            fine = print.fine
            width = print.width
            height = print.height
            byteCount = print.byteCount
        }
    }

    private struct DisjointSet {
        private var parent: [Int]
        /// Every index currently under each root, kept alongside `parent` so
        /// `groupSimilar`'s clique guard can list a candidate group's members
        /// without a separate O(n) walk over every index for every pair it
        /// considers. Only ever appended to on the surviving root, which is
        /// what keeps the running total cost of every union linear over the
        /// whole pass rather than quadratic.
        private var members: [[Int]]

        init(_ count: Int) {
            parent = Array(0..<count)
            members = (0..<count).map { [$0] }
        }

        mutating func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var walk = index
            while parent[walk] != root {
                let next = parent[walk]
                parent[walk] = root
                walk = next
            }
            return root
        }

        mutating func union(_ lhs: Int, _ rhs: Int) {
            let a = find(lhs), b = find(rhs)
            guard a != b else { return }
            parent[b] = a
            members[a].append(contentsOf: members[b])
            members[b].removeAll()
        }

        /// Only meaningful when `root` is already a root (the result of
        /// `find`, not a raw index) -- callers that pass anything else get an
        /// empty or stale list back.
        func groupMembers(ofRoot root: Int) -> [Int] { members[root] }
    }
}
