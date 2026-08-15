import UIKit
import Photos

@MainActor
final class PhotoSaver: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case saving(done: Int, total: Int)
        case finished(succeeded: Int, failed: Int, message: String?)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
        let isError: Bool
    }

    @Published private(set) var state: SaveState = .idle
    /// Human-readable trace of the last save run, surfaced in the UI so problems
    /// are diagnosable on-device (an extension has no console to check).
    @Published private(set) var log: [LogEntry] = []

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    func save(_ images: [PageImage]) async {
        guard !images.isEmpty else { return }

        log.removeAll()
        appendLog("保存開始: \(images.count)件")
        appendLog("権限状態: \(authorizationDescription)")

        let authorized = await requestAddOnlyAuthorization()
        appendLog("権限リクエスト後: \(authorizationDescription)")

        guard authorized else {
            appendLog("写真へのアクセスが拒否されました", isError: true)
            state = .finished(
                succeeded: 0,
                failed: images.count,
                message: "写真へのアクセスが許可されていません。\n「設定」→「プライバシーとセキュリティ」→「写真」→「ImageSaver」で許可してください。"
            )
            return
        }

        let beforeCount = photoLibraryCount()
        appendLog("保存前の写真総数: \(beforeCount)")

        state = .saving(done: 0, total: images.count)

        var succeeded = 0
        var failed = 0
        var lastError: String?

        // Bounded concurrency keeps memory in check when saving many large photos at once.
        let semaphore = AsyncSemaphore(limit: 4)

        await withTaskGroup(of: (String, Result<Void, Error>).self) { group in
            for image in images {
                group.addTask { [weak self] in
                    guard let self else { return ("", .failure(SaveError.cancelled)) }
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    let result = await self.saveOne(image)
                    return (image.url.lastPathComponent, result)
                }
            }

            for await (name, result) in group {
                switch result {
                case .success:
                    succeeded += 1
                    appendLog("OK: \(name)")
                case .failure(let error):
                    failed += 1
                    lastError = error.localizedDescription
                    appendLog("失敗: \(name) — \(error.localizedDescription)", isError: true)
                }
                state = .saving(done: succeeded + failed, total: images.count)
            }
        }

        let afterCount = photoLibraryCount()
        appendLog("保存後の写真総数: \(afterCount) (増加 \(afterCount - beforeCount))")

        if succeeded > 0 && afterCount == beforeCount {
            appendLog("警告: 保存は成功したはずですが写真総数が増えていません", isError: true)
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

    private func appendLog(_ text: String, isError: Bool = false) {
        log.append(LogEntry(time: Date(), text: text, isError: isError))
    }

    private var authorizationDescription: String {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .notDetermined: return "未確認"
        case .restricted: return "制限あり"
        case .denied: return "拒否"
        case .authorized: return "許可"
        case .limited: return "一部のみ許可"
        @unknown default: return "不明"
        }
    }

    /// Counting assets requires read access; with add-only permission this
    /// returns 0, so treat it as a hint rather than proof.
    private func photoLibraryCount() -> Int {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            return -1
        }
        return PHAsset.fetchAssets(with: .image, options: nil).count
    }

    private func saveOne(_ image: PageImage) async -> Result<Void, Error> {
        do {
            let (data, response) = try await session.data(from: image.url)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SaveError.httpError(http.statusCode)
            }

            if image.isSVG {
                // Photos can't store SVG, so rasterize to a PNG first.
                let rendered = try SVGRasterizer.rasterize(data: data, maxPixelSize: 2048)
                guard let pngData = rendered.pngData() else {
                    throw SaveError.decodeFailed
                }
                try await addToLibrary(data: pngData, fileExtension: "png")
            } else {
                // Save the original bytes so quality and metadata survive intact.
                guard UIImage(data: data) != nil else {
                    throw SaveError.decodeFailed
                }
                let ext = image.url.pathExtension.isEmpty ? "jpg" : image.url.pathExtension
                try await addToLibrary(data: data, fileExtension: ext)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func addToLibrary(data: Data, fileExtension: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "ImageSaver-\(UUID().uuidString).\(fileExtension)"
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
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .decodeFailed: return "画像を読み込めませんでした"
        case .cancelled: return "保存が中断されました"
        case .httpError(let code): return "ダウンロード失敗 (HTTP \(code))"
        }
    }
}
