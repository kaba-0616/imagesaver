import UIKit
import Photos

@MainActor
final class PhotoSaver: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case saving(done: Int, total: Int)
        case finished(succeeded: Int, failed: Int)
    }

    @Published private(set) var state: SaveState = .idle

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    func save(_ images: [PageImage]) async {
        guard !images.isEmpty else { return }

        let authorized = await requestAddOnlyAuthorization()
        guard authorized else {
            state = .finished(succeeded: 0, failed: images.count)
            return
        }

        state = .saving(done: 0, total: images.count)

        var succeeded = 0
        var failed = 0

        // Bounded concurrency keeps memory in check when saving many large photos at once.
        let semaphore = AsyncSemaphore(limit: 4)

        await withTaskGroup(of: Bool.self) { group in
            for image in images {
                group.addTask { [weak self] in
                    guard let self else { return false }
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    return await self.saveOne(image)
                }
            }

            for await success in group {
                if success { succeeded += 1 } else { failed += 1 }
                state = .saving(done: succeeded + failed, total: images.count)
            }
        }

        state = .finished(succeeded: succeeded, failed: failed)
    }

    func reset() {
        state = .idle
    }

    private func saveOne(_ image: PageImage) async -> Bool {
        do {
            let (data, _) = try await session.data(from: image.url)
            guard let uiImage = UIImage(data: data) else {
                throw ImageLoadError.decodeFailed
            }

            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
            }
            return true
        } catch {
            return false
        }
    }

    private func requestAddOnlyAuthorization() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return newStatus == .authorized || newStatus == .limited
        default:
            return false
        }
    }
}
