import Foundation

struct DuplicateGroup: Identifiable {
    enum Kind {
        case identical
        case similar

        var label: String {
            switch self {
            case .identical: return "同じ写真"
            case .similar: return "似ている写真"
            }
        }
    }

    let id: Int
    let kind: Kind
    /// Best first: the one worth keeping is members[0].
    let members: [PhotoFingerprint]

    var suggestedKeep: PhotoFingerprint { members[0] }
    var suggestedDelete: [PhotoFingerprint] { Array(members.dropFirst()) }
}

enum Sensitivity: Int, CaseIterable, Identifiable {
    case strict = 4
    case standard = 8
    case loose = 12

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .strict: return "厳しめ"
        case .standard: return "標準"
        case .loose: return "緩め"
        }
    }

    var detail: String {
        switch self {
        case .strict: return "ほぼ同じ写真だけ"
        case .standard: return "見比べて同じと思える程度"
        case .loose: return "連写や撮り直しも拾う"
        }
    }
}

enum DuplicateGrouper {

    /// Photographs of the same scene form a chain -- A resembles B, B
    /// resembles C -- so a group can grow past what any two members have in
    /// common. That is the behaviour wanted for a burst, and the reason the
    /// sensitivity is offered rather than fixed.
    static func group(_ prints: [PhotoFingerprint], sensitivity: Sensitivity) -> [DuplicateGroup] {
        guard prints.count > 1 else { return [] }

        var sets = DisjointSet(prints.count)

        // Same picture, byte-for-byte or near enough that 256 bits cannot tell
        // them apart. Found by lookup rather than comparison, so it costs
        // nothing even on a large library.
        var byExact: [ExactKey: Int] = [:]
        byExact.reserveCapacity(prints.count)
        for (index, print) in prints.enumerated() {
            let key = ExactKey(fine: print.fine, width: print.width, height: print.height)
            if let first = byExact[key] {
                sets.union(first, index)
            } else {
                byExact[key] = index
            }
        }

        // A burst is a group the camera already decided on.
        var byBurst: [String: Int] = [:]
        for (index, print) in prints.enumerated() {
            guard let burst = print.burstIdentifier else { continue }
            if let first = byBurst[burst] {
                sets.union(first, index)
            } else {
                byBurst[burst] = index
            }
        }

        // Flat arrays: the inner loop runs tens of millions of times and
        // reaching through a struct for each field is most of the cost.
        let coarse = prints.map(\.coarse)
        let aspects = prints.map(\.aspect)
        let threshold = sensitivity.rawValue

        for i in 0..<prints.count {
            let hashI = coarse[i]
            let aspectI = aspects[i]
            for j in (i + 1)..<prints.count {
                if (hashI ^ coarse[j]).nonzeroBitCount > threshold { continue }
                // A portrait and a landscape squashed onto the same grid can
                // score alike without looking alike.
                let ratio = aspectI / aspects[j]
                if ratio < 0.88 || ratio > 1.14 { continue }
                sets.union(i, j)
            }
        }

        var buckets: [Int: [PhotoFingerprint]] = [:]
        for index in 0..<prints.count {
            buckets[sets.find(index), default: []].append(prints[index])
        }

        var groups: [DuplicateGroup] = []
        for (root, members) in buckets where members.count > 1 {
            let ordered = members.sorted(by: keepFirst)
            let key = ExactKey(fine: ordered[0].fine, width: ordered[0].width, height: ordered[0].height)
            let allIdentical = ordered.allSatisfy {
                ExactKey(fine: $0.fine, width: $0.width, height: $0.height) == key
            }
            groups.append(DuplicateGroup(id: root,
                                         kind: allIdentical ? .identical : .similar,
                                         members: ordered))
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

    /// Favourites first so they are never the copy that gets dropped, then the
    /// largest, then the oldest -- the original rather than a re-save.
    private static func keepFirst(_ lhs: PhotoFingerprint, _ rhs: PhotoFingerprint) -> Bool {
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        if lhs.pixels != rhs.pixels { return lhs.pixels > rhs.pixels }
        switch (lhs.creationDate, rhs.creationDate) {
        case let (l?, r?) where l != r: return l < r
        default: return lhs.localIdentifier < rhs.localIdentifier
        }
    }

    private struct ExactKey: Hashable {
        let fine: FineHash
        let width: Int
        let height: Int
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
