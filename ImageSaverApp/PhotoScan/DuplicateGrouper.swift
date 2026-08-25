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
enum DuplicateLevel {

    static let range = 0...10
    /// Matches build 69 "標準". Starting at 10 would open the similar tab
    /// empty, which reads as the feature being broken rather than strict.
    static let standard = 6

    private static let key = "photoScanLevel"

    static func clamp(_ level: Int) -> Int {
        min(max(level, range.lowerBound), range.upperBound)
    }

    static func distance(for level: Int) -> Int {
        (range.upperBound - clamp(level)) * 2
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

    /// Groups sharing an exact fine-hash+dimensions key or a burst id, and
    /// nothing else -- no hamming threshold, no crop pass. This is what
    /// `.identical` membership has always actually reduced to (see
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
                             progress: (@Sendable (Double) -> Void)? = nil) -> Result {
        guard prints.count > 1 else {
            return Result(groups: [], cropMS: 0, cropCandidatePairs: 0, largestWidthBucket: 0,
                         cropCache: nil, cropReused: false)
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

        for i in 0..<count {
            if let progress, i % 256 == 0, totalPairs > 0 {
                let donePairs = i * (2 * count - i - 1) / 2
                progress(Double(donePairs) / Double(totalPairs) * mainWeight)
            }
            let hashI = coarse[i]
            let aspectI = aspects[i]
            for j in (i + 1)..<count {
                if (hashI ^ coarse[j]).nonzeroBitCount > threshold { continue }
                // A portrait and a landscape squashed onto the same grid can
                // score alike without looking alike. Written as a positive test
                // so a NaN -- either side missing its pixel size -- fails it
                // rather than slipping through two negative ones.
                let ratio = aspectI / aspects[j]
                if !(ratio >= 0.88 && ratio <= 1.14) { continue }
                if hasRejections && rejectedPairs.contains(pairKey(i, j)) { continue }
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
                     cropReused: cropCache != nil)
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

    private static func meanAbsDifference(_ a: Data, _ b: Data) -> Double {
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
    private static func timestamp(_ print: PhotoFingerprint) -> TimeInterval {
        print.creationDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
    }

    private struct ExactKey: Hashable {
        let fine: FineHash
        let width: Int
        let height: Int

        init(_ print: PhotoFingerprint) {
            fine = print.fine
            width = print.width
            height = print.height
        }
    }

    private struct DisjointSet {
        private var parent: [Int]

        init(_ count: Int) { parent = Array(0..<count) }

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
            if a != b { parent[b] = a }
        }
    }
}
