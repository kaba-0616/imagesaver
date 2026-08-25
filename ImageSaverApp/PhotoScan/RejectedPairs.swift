import Foundation

/// One press of "these are different photos": the members the user judged
/// apart, and when.
///
/// The decision is the unit that is stored, not the pair. A 50 shot burst is
/// 1225 pairs, and each identifier is 42 characters -- written out as pairs
/// that is over a hundred kilobytes for one press. The pairs the grouping
/// needs are expanded from this in memory instead.
struct RejectionDecision: Codable, Equatable {
    let at: Date
    let members: [String]
    /// Which tab the press happened on. "≠" now excludes a pair only from
    /// the grouping it was pressed against -- a duplicate-tab rejection says
    /// nothing about whether the same two photos are similar, and the other
    /// way round -- so the tab it came from is part of the decision, not
    /// metadata about it.
    let kind: DuplicateGroup.Kind
}

/// The file behind RejectedPairs. Nothing here is actor isolated, so the
/// writing can happen off the main thread without any of it having to be.
enum RejectionFile {

    private static let name = "exclusions.json"
    private static let version = 1
    private static let queue = DispatchQueue(label: "jp.kaba.imagesaver.rejections", qos: .utility)

    /// Identifiers are held once in `ids` and referred to by index, because
    /// the same photo appears in most of the decisions that mention it.
    private struct Stored: Codable {
        struct Entry: Codable {
            let at: Date
            let members: [Int]
            let kind: DuplicateGroup.Kind

            init(at: Date, members: [Int], kind: DuplicateGroup.Kind) {
                self.at = at
                self.members = members
                self.kind = kind
            }

            // A file written before kind-scoping existed has no `kind` key
            // at all. Every decision on disk at that point was pressed on
            // the similar tab in practice (duplicate-tab rejection wasn't
            // something anyone had done yet), so that is the fallback --
            // not a guess so much as what the missing field always meant.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                at = try container.decode(Date.self, forKey: .at)
                members = try container.decode([Int].self, forKey: .members)
                kind = try container.decodeIfPresent(DuplicateGroup.Kind.self, forKey: .kind) ?? .similar
            }

            private enum CodingKeys: String, CodingKey {
                case at, members, kind
            }
        }
        let version: Int
        let ids: [String]
        let decisions: [Entry]
    }

    static func load() -> [RejectionDecision] {
        guard let url = PhotoScanStore.url(name),
              let data = try? Data(contentsOf: url),
              let stored = try? PhotoScanStore.decoder().decode(Stored.self, from: data)
        else { return [] }

        var result: [RejectionDecision] = []
        result.reserveCapacity(stored.decisions.count)
        for entry in stored.decisions {
            var members: [String] = []
            members.reserveCapacity(entry.members.count)
            for index in entry.members where index >= 0 && index < stored.ids.count {
                members.append(stored.ids[index])
            }
            guard members.count > 1 else { continue }
            result.append(RejectionDecision(at: entry.at, members: members, kind: entry.kind))
        }
        return result
    }

    /// Returns nil on success, or something printable to show the user.
    /// A fingerprint can be recomputed; this cannot, so the failure is never
    /// swallowed and the card is only removed once this has come back nil.
    static func save(_ decisions: [RejectionDecision]) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: write(decisions))
            }
        }
    }

    private static func write(_ decisions: [RejectionDecision]) -> String? {
        guard let url = PhotoScanStore.url(name) else {
            return "保存先のフォルダを開けませんでした"
        }
        var ids: [String] = []
        var indexByID: [String: Int] = [:]
        var entries: [Stored.Entry] = []
        entries.reserveCapacity(decisions.count)
        for decision in decisions {
            var members: [Int] = []
            members.reserveCapacity(decision.members.count)
            for identifier in decision.members {
                if let index = indexByID[identifier] {
                    members.append(index)
                } else {
                    let index = ids.count
                    ids.append(identifier)
                    indexByID[identifier] = index
                    members.append(index)
                }
            }
            entries.append(Stored.Entry(at: decision.at, members: members, kind: decision.kind))
        }

        let stored = Stored(version: version, ids: ids, decisions: entries)
        do {
            let data = try PhotoScanStore.encoder().encode(stored)
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The photos the user has said are not the same, kept across runs.
///
/// Deliberately global rather than per level: keeping a separate set for each
/// of the eleven slider positions is more machinery than the problem is worth,
/// and a judgement about two photographs does not change because the slider
/// moved.
@MainActor
final class RejectedPairs {

    enum Outcome: Equatable {
        case saved
        /// A save is already on its way to disk. Nothing was written and
        /// nothing was lost; the caller has to say so rather than act as if
        /// the decision had been kept.
        case busy
        /// Fewer than two members, so there was no pair to record. Told apart
        /// from `.saved` because nothing went into the store: a caller that
        /// treated it as success would remove a card and offer an undo that
        /// would then take back somebody else's decision.
        case nothingToStore
        case groupTooLarge(Int)
        case storeFull(Int)
        case failed(String)
    }

    /// 256 members is 32640 pairs, which is as much as the run time expansion
    /// should ever be asked to hold for one decision.
    static let maxMembersPerDecision = 256
    static let maxTotalPairs = 200_000

    private(set) var decisions: [RejectionDecision] = []
    private var loaded = false
    /// True from the moment a write starts until it has come back.
    ///
    /// `decisions` is only updated once the file has been written -- the card
    /// must not disappear over a save that failed -- which means the update
    /// sits on the far side of an await. Two presses in a row would then both
    /// read the old array and the first decision would be gone from memory and
    /// from the file. Being on the main actor does not help: an await is a
    /// suspension point, and the second press runs in the gap.
    private var saving = false

    /// What DuplicateGrouper is handed for one tab's grouping. Sets of
    /// identifiers, expanded into index pairs inside the grouping itself --
    /// the indices belong to it. Scoped to `kind` because a rejection now
    /// only ever excludes the pair from the tab it was pressed on.
    func memberSets(for kind: DuplicateGroup.Kind) -> [Set<String>] {
        decisions.filter { $0.kind == kind }.map { Set($0.members) }
    }

    var count: Int { decisions.count }

    func count(for kind: DuplicateGroup.Kind) -> Int {
        decisions.filter { $0.kind == kind }.count
    }

    var pairCount: Int { decisions.reduce(0) { $0 + Self.pairs(in: $1.members.count) } }

    func loadIfNeeded() {
        guard !loaded else { return }
        decisions = RejectionFile.load()
        loaded = true
    }

    func add(_ members: [String], kind: DuplicateGroup.Kind) async -> Outcome {
        guard !saving else { return .busy }
        let unique = Array(Set(members))
        guard unique.count > 1 else { return .nothingToStore }
        guard unique.count <= Self.maxMembersPerDecision else {
            return .groupTooLarge(unique.count)
        }
        let projected = pairCount + Self.pairs(in: unique.count)
        guard projected <= Self.maxTotalPairs else { return .storeFull(projected) }

        var next = decisions
        next.append(RejectionDecision(at: Date(), members: unique, kind: kind))
        return await write(next)
    }

    func undoLast() async -> Outcome {
        guard !saving else { return .busy }
        guard !decisions.isEmpty else { return .saved }
        var next = decisions
        next.removeLast()
        return await write(next)
    }

    /// Clears only the decisions made on `kind`'s tab, leaving the other
    /// tab's exclusions untouched -- the two are independent now, so
    /// "clear" has to be too.
    func removeAll(kind: DuplicateGroup.Kind) async -> Outcome {
        guard !saving else { return .busy }
        let remaining = decisions.filter { $0.kind != kind }
        guard remaining.count != decisions.count else { return .saved }
        return await write(remaining)
    }

    /// The one place `decisions` is replaced, and the only thing the flag has
    /// to be wrapped around.
    private func write(_ next: [RejectionDecision]) async -> Outcome {
        saving = true
        defer { saving = false }
        if let error = await RejectionFile.save(next) { return .failed(error) }
        decisions = next
        return .saved
    }

    private static func pairs(in count: Int) -> Int {
        count > 1 ? count * (count - 1) / 2 : 0
    }
}
