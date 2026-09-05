import Foundation

/// The photos the user has said "don't suggest trimming this" for, kept
/// across runs, along with the exact margin that was on screen when they
/// said so. Unlike `RejectedPairs` this is single-photo, not pairwise --
/// margin review only ever judges one photo at a time.
///
/// Recording the margin (not just the identifier) matters: a "don't trim
/// this" decision is really a decision about a specific *suggestion*, not a
/// blanket "never touch this photo again". If a later scan (a detector
/// change, a different sensitivity level) finds a margin in a materially
/// different place on the same photo, that is a different suggestion the
/// user never actually saw, so it should be offered rather than silently
/// swallowed forever just because the identifier happens to match.
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

    private(set) var entries: [String: MarginResult] = [:]
    private var loaded = false
    private var saving = false

    var count: Int { entries.count }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = PhotoScanStore.url(Self.name),
              let data = try? Data(contentsOf: url)
        else { return }
        // Reads the old plain-identifier-list format (pre-margin-tracking)
        // as "no recorded margin" rather than discarding it outright -- a
        // photo skipped under that format is still skipped for whatever
        // margin comes up next; it will only start reappearing for a
        // genuinely different margin from here on, same as a fresh entry.
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: list.map { ($0, MarginResult(top: -1, bottom: -1, left: -1, right: -1)) })
        } else if let dict = try? JSONDecoder().decode([String: MarginResult].self, from: data) {
            entries = dict
        }
    }

    /// `margin` is the suggestion actually shown when the user chose to
    /// skip -- required so a future scan can tell whether it is looking at
    /// the same suggestion or a new one.
    func add(_ identifier: String, margin: MarginResult) async -> Outcome {
        guard !saving else { return .busy }
        guard entries.count < Self.maxCount else { return .storeFull }
        var next = entries
        next[identifier] = margin
        return await write(next)
    }

    func removeAll() async -> Outcome {
        guard !saving else { return .busy }
        return await write([:])
    }

    private func write(_ next: [String: MarginResult]) async -> Outcome {
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
        entries = next
        return .saved
    }
}
