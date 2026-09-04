import Foundation

/// The photos the user has said "don't suggest trimming this" for, kept
/// across runs. Unlike `RejectedPairs` this is single-photo, not pairwise --
/// margin review only ever judges one photo at a time -- so the storage
/// collapses to a plain capped set of identifiers.
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

    private(set) var identifiers: Set<String> = []
    private var loaded = false
    private var saving = false

    var count: Int { identifiers.count }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = PhotoScanStore.url(Self.name),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        identifiers = Set(list)
    }

    func add(_ identifier: String) async -> Outcome {
        guard !saving else { return .busy }
        guard identifiers.count < Self.maxCount else { return .storeFull }
        var next = identifiers
        next.insert(identifier)
        return await write(next)
    }

    func removeAll() async -> Outcome {
        guard !saving else { return .busy }
        return await write([])
    }

    private func write(_ next: Set<String>) async -> Outcome {
        saving = true
        defer { saving = false }
        guard let url = PhotoScanStore.url(Self.name) else {
            return .failed("保存先のフォルダを開けませんでした")
        }
        let list = Array(next)
        let failure: String? = await withCheckedContinuation { continuation in
            Self.queue.async {
                do {
                    let data = try JSONEncoder().encode(list)
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
        if let failure { return .failed(failure) }
        identifiers = next
        return .saved
    }
}
