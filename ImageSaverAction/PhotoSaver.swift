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
        let text: String
        let isError: Bool
    }

    @Published private(set) var state: SaveState = .idle

    var isSaving: Bool {
        if case .saving = state { return true }
        return false
    }
    /// Human-readable trace of the last save run, surfaced in the UI so problems
    /// are diagnosable on-device (an extension has no console to check).
    @Published private(set) var log: [LogEntry] = []
    /// IDs that made it into the photo library; the grid hides these.
    @Published private(set) var savedImageIDs: Set<Int> = []

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    func save(_ images: [PageImage]) async {
        log.removeAll()

        guard !images.isEmpty else {
            appendLog("保存対象が0件です", isError: true)
            state = .finished(succeeded: 0, failed: 0, message: "画像が選択されていません")
            return
        }

        // Show the progress overlay immediately so the tap is always acknowledged,
        // even before the permission prompt appears.
        state = .saving(done: 0, total: images.count)
        appendLog("保存開始: \(images.count)件")

        // Requesting Photos access without this key in the extension's own
        // Info.plist terminates the process immediately, which looks like the
        // share sheet simply closing.
        let usageDescription = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String
        appendLog("説明文の有無: \(usageDescription == nil ? "なし(致命的)" : "あり")", isError: usageDescription == nil)

        guard usageDescription != nil else {
            state = .finished(
                succeeded: 0,
                failed: images.count,
                message: "アプリの設定不備です(写真アクセスの説明文が未設定)。開発者に報告してください。"
            )
            return
        }

        appendLog("権限状態: \(authorizationDescription)")

        // Raising the system permission prompt from inside an action extension
        // terminates the process on iOS 26, so the prompt has to be answered in
        // the container app first. Here we only read the existing decision.
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status != .notDetermined else {
            appendLog("未許可のため中止(本体アプリで許可が必要)", isError: true)
            state = .finished(
                succeeded: 0,
                failed: images.count,
                message: "先にホーム画面の「ImageSaver」アプリを開き、「写真への保存を許可する」をタップしてください。"
            )
            return
        }

        let authorized = (status == .authorized || status == .limited)

        guard authorized else {
            appendLog("写真へのアクセスが拒否されました", isError: true)
            state = .finished(
                succeeded: 0,
                failed: images.count,
                message: "写真へのアクセスが許可されていません。\n「設定」→「プライバシーとセキュリティ」→「写真」→「ImageSaver」で許可してください。"
            )
            return
        }

        var succeeded = 0
        var failed = 0
        var lastError: String?

        // Bounded concurrency keeps memory in check when saving many large photos at once.
        let semaphore = AsyncSemaphore(limit: 4)

        await withTaskGroup(of: (Int, String, Result<Void, Error>).self) { group in
            for image in images {
                group.addTask { [weak self] in
                    guard let self else { return (image.id, "", .failure(SaveError.cancelled)) }
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    let result = await self.saveOne(image)
                    return (image.id, image.url.lastPathComponent, result)
                }
            }

            for await (id, name, result) in group {
                switch result {
                case .success:
                    succeeded += 1
                    savedImageIDs.insert(id)
                    appendLog("OK: \(name)")
                case .failure(let error):
                    failed += 1
                    lastError = error.localizedDescription
                    appendLog("失敗: \(name) — \(error.localizedDescription)", isError: true)
                }
                state = .saving(done: succeeded + failed, total: images.count)
            }
        }

        appendLog("完了: 成功\(succeeded) 失敗\(failed)")

        state = .finished(
            succeeded: succeeded,
            failed: failed,
            message: failed > 0 ? lastError : nil
        )
    }

    private func appendLog(_ text: String, isError: Bool = false) {
        log.append(LogEntry(text: text, isError: isError))
        // Persist after every line: if the extension is killed mid-save the log
        // is still readable on the next launch, which is the only way to see
        // what happened when the host tears the UI down.
        PersistentLog.write(log)
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
                try await addToLibrary(
                    data: data,
                    fileExtension: fileExtension(for: image.url, response: response)
                )
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Plenty of image URLs carry no extension, and defaulting those to "jpg"
    /// files a PNG or WebP under the wrong type. The server's own content type
    /// is the more reliable answer when the URL has nothing to offer.
    private func fileExtension(for url: URL, response: URLResponse) -> String {
        let fromURL = url.pathExtension.lowercased()
        if !fromURL.isEmpty { return fromURL }

        switch response.mimeType?.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        case "image/tiff": return "tiff"
        default: return "jpg"
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
