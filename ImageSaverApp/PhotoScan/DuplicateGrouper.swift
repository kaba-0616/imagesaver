import Foundation

struct DuplicateGroup: Identifiable {

    enum Kind: Hashable, CaseIterable {
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

    var suggestedKeep: PhotoFingerprint { members[0] }
    var suggestedDelete: [PhotoFingerprint] { Array(members.dropFirst()) }

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
    static func group(_ prints: [PhotoFingerprint],
                      level: Int,
                      rejected: [Set<String>],
                      progress: (@Sendable (Double) -> Void)? = nil) -> [DuplicateGroup] {
        guard prints.count > 1 else { return [] }
        let count = prints.count

        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(count)
        for (index, print) in prints.enumerated() {
            indexByID[print.localIdentifier] = index
        }

        // Identifier sets in, packed index pairs out. The inner loop below runs
        // tens of millions of times and cannot afford to look anything up by
        // string.
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

        var sets = DisjointSet(count)

        // Same picture, byte-for-byte or near enough that 256 bits cannot tell
        // them apart. Found by lookup rather than comparison, so it costs
        // nothing even on a large library.
        var byExact: [ExactKey: [Int]] = [:]
        byExact.reserveCapacity(count)
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

        // Flat arrays: the inner loop runs tens of millions of times and
        // reaching through a struct for each field is most of the cost.
        let coarse = prints.map(\.coarse)
        let aspects = prints.map(\.aspect)
        let threshold = DuplicateLevel.distance(for: level)
        let hasRejections = !rejectedPairs.isEmpty
        // The work is a triangle, so i/n would claim half done a quarter of the
        // way through. Pairs are what actually gets done.
        let totalPairs = count * (count - 1) / 2

        for i in 0..<count {
            if let progress, i % 256 == 0, totalPairs > 0 {
                let donePairs = i * (2 * count - i - 1) / 2
                progress(Double(donePairs) / Double(totalPairs))
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
        progress?(1)

        var buckets: [Int: [Int]] = [:]
        for index in 0..<count {
            buckets[sets.find(index), default: []].append(index)
        }

        var groups: [DuplicateGroup] = []
        for (root, indices) in buckets where indices.count > 1 {
            let members = indices.map { prints[$0] }
            // Which tab the group lands on, and nothing else: both tabs are
            // ranked by the same rule, and whether every member is the same
            // picture does not depend on their order.
            let kind = self.kind(of: members)
            let flagged = hasRejections
                && containsRejectedPair(indices, in: rejectedPairs, touching: rejectedIndices)
            groups.append(DuplicateGroup(id: root,
                                         kind: kind,
                                         members: order(members),
                                         hasRejectedPair: flagged))
        }

        // Exact matches first, then the biggest groups: the clearest decisions
        // come first and the judgement calls come after.
        return groups.sorted { lhs, rhs in
            if (lhs.kind == .identical) != (rhs.kind == .identical) {
                return lhs.kind == .identical
            }
            if lhs.members.count != rhs.members.count {
                return lhs.members.count > rhs.members.count
            }
            return lhs.id < rhs.id
        }
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
    static func order(_ members: [PhotoFingerprint]) -> [PhotoFingerprint] {
        members.sorted(by: sizesKnown(members) ? bestFirstWithSize : bestFirstWithoutSize)
    }

    /// All or nothing: mixing "by size" and "without size" inside one group is
    /// not a consistent ordering, and an inconsistent comparison is a sorting
    /// bug waiting to happen. Exposed because whoever writes the log has to
    /// say which of the two orderings was actually used.
    static func sizesKnown(_ members: [PhotoFingerprint]) -> Bool {
        members.allSatisfy { ($0.byteCount ?? 0) > 0 }
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
