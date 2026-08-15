import UIKit
import Photos

@MainActor
final class PhotoSaver: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case saving(done: Int, total: Int)
        case finished(succeeded: Int, failed: Int, message: String?)
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
            state = .finished(
                succeeded: 0,
                failed: images.count,
                message: "写真へのアクセスが許可されていません。\n「設定」→「プライバシーとセキュリティ」→「写真」→「ImageSaver」で許可してください。"
            )
            return
        }

        state = .saving(done: 0, total: images.count)

        var succeeded = 0
        var failed = 0
        var lastError: String?

        // Bounded concurrency keeps memory in check when saving many large photos at once.
        let semaphore = AsyncSemaphore(limit: 4)

        await withTaskGroup(of: Result<Void, Error>.self) { group in
            for image in images {
                group.addTask { [weak self] in
                    guard let self else { return .failure(SaveError.cancelled) }
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    return await self.saveOne(image)
                }
            }

            for await result in group {
                switch result {
                case .success:
                    succeeded += 1
                case .failure(let error):
                    failed += 1
                    lastError = error.localizedDescription
                }
                state = .saving(done: succeeded + failed, total: images.count)
            }
        }

        state = .finished(
            succeeded: succeeded,
            failed: failed,
            message: failed > 0 ? lastError : nil
        )
    }

    func reset() {
        state = .idle
    }

    private func saveOne(_ image: PageImage) async -> Result<Void, Error> {
        do {
            let (data, _) = try await session.data(from: image.url)

            if image.isSVG {
                // Photos can't store SVG, so rasterize to a PNG first.
                let rendered = try SVGRasterizer.rasterize(data: data, maxPixelSize: 2048)
                guard let pngData = rendered.pngData() else {
                    throw SaveError.decodeFailed
                }
                try await addToLibrary(data: pngData)
            } else {
                // Save the original bytes so quality and metadata survive intact.
                guard UIImage(data: data) != nil else {
                    throw SaveError.decodeFailed
                }
                try await addToLibrary(data: data)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func addToLibrary(data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "ImageSaver-\(UUID().uuidString).jpg"
            request.addResource(with: .photo, data: data, options: options)
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

enum SaveError: LocalizedError {
    case decodeFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .decodeFailed: return "画像を読み込めませんでした"
        case .cancelled: return "保存が中断されました"
        }
    }
}
