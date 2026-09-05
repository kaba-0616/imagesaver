import Foundation

/// The photos the user has said "don't suggest trimming this" for, kept
/// across runs, along with the exact margin that was on screen when they
/// said so, in the order they were decided. Unlike `RejectedPairs` this is
/// single-photo, not pairwise -- margin review only ever judges one photo at
/// a time.
///
/// Recording the margin (not just the identifier) matters: a "don't trim
/// this" decision is really a decision about a specific *suggestion*, not a
/// blanket "never touch this photo again". If a later scan (a detector
/// change, a different sensitivity level) finds a margin in a materially
/// different place on the same photo, that is a different suggestion the
/// user never actually saw, so it should be offered rather than silently
/// swallowed forever just because the identifier happens to match.
///
/// Recording insertion order (not just a set) matters too: it is what lets
/// `undoLast()` mirror `RejectedPairs.undoLast()` -- "take back the most
/// recent decision" -- rather than only ever being able to clear everything
/// at once.
@MainActor
final class MarginCropSkipped {

    private static let name = "margincrop-skipped.json"
    private static let maxCount = 20_000
    private static let queue = DispatchQueue(label: "jp.kaba.imagesaver.margincrop.skipped", qos: .utility)

    enum Outcome: Equatable {
        case saved
        case busy
        case storeFull
        case failed(String)
    }

    struct Entry: Codable {
        let identifier: String
        let margin: MarginResult
    }

    private(set) var decisions: [Entry] = []
    private var loaded = false
    private var saving = false

    var count: Int { decisions.count }

    /// The margin recorded for each skipped identifier, for the scanner's
    /// re-scan comparison. A photo skipped more than once (most recently
    /// under the current margin-aware format) keeps only its newest
    /// decision live here.
    var entries: [String: MarginResult] {
        var result: [String: MarginResult] = [:]
        for entry in decisions { result[entry.identifier] = entry.margin }
        return result
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = PhotoScanStore.url(Self.name),
              let data = try? Data(contentsOf: url)
        else { return }
        if let list = try? JSONDecoder().decode([Entry].self, from: data) {
            decisions = list
        } else if let dict = try? JSONDecoder().decode([String: MarginResult].self, from: data) {
            // build174's format -- no reliable insertion order to recover,
            // so these land at the front (oldest) rather than being eligible
            // for undo.
            decisions = dict.map { Entry(identifier: $0.key, margin: $0.value) }
        } else if let list = try? JSONDecoder().decode([String].self, from: data) {
            // Pre-margin-tracking format: no recorded margin means "no
            // recorded margin", not "no margin" (see `MarginCropScanner
            // .isSkipped`'s use of `-1` sentinels never matching a real
            // detection) -- these are surfaced once more on the next scan
            // and then re-recorded under the current format.
            let sentinel = MarginResult(top: -1, bottom: -1, left: -1, right: -1)
            decisions = list.map { Entry(identifier: $0, margin: sentinel) }
        }
    }

    /// `margin` is the suggestion actually shown when the user chose to
    /// skip -- required so a future scan can tell whether it is looking at
    /// the same suggestion or a new one. Skipping the same identifier again
    /// replaces its old entry rather than appending a duplicate, and moves
    /// it to the end (most recent) so `undoLast()` finds it there.
    func add(_ identifier: String, margin: MarginResult) async -> Outcome {
        guard !saving else { return .busy }
        guard decisions.count < Self.maxCount else { return .storeFull }
        var next = decisions
        next.removeAll { $0.identifier == identifier }
        next.append(Entry(identifier: identifier, margin: margin))
        return await write(next)
    }

    /// Removes the most recently added decision -- the persisted
    /// counterpart to the scanner's in-memory undo stack, mirroring
    /// `RejectedPairs.undoLast()`. A no-op (not a failure) when there is
    /// nothing to undo, same as that sibling.
    func undoLast() async -> Outcome {
        guard !saving else { return .busy }
        guard !decisions.isEmpty else { return .saved }
        var next = decisions
        next.removeLast()
        return await write(next)
    }

    func removeAll() async -> Outcome {
        guard !saving else { return .busy }
        return await write([])
    }

    private func write(_ next: [Entry]) async -> Outcome {
        saving = true
        defer { saving = false }
        guard let url = PhotoScanStore.url(Self.name) else {
            return .failed("保存先のフォルダを開けませんでした")
        }
        let failure: String? = await withCheckedContinuation { continuation in
            Self.queue.async {
                do {
                    let data = try JSONEncoder().encode(next)
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
        if let failure { return .failed(failure) }
        decisions = next
        return .saved
    }
}
