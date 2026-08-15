import UIKit
import ImageIO

@MainActor
final class ImageLoader: ObservableObject {

    static let shared = ImageLoader()

    @Published private(set) var thumbnails: [Int: UIImage] = [:]
    @Published private(set) var fullImages: [Int: UIImage] = [:]
    @Published private(set) var failed: Set<Int> = []

    private var tasks: [Int: Task<Void, Never>] = [:]
    private var fullImageTasks: [Int: Task<Void, Never>] = [:]
    private let semaphore = AsyncSemaphore(limit: 6)
    private let fullImageSemaphore = AsyncSemaphore(limit: 2)
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    func requestThumbnail(for image: PageImage, maxPixelSize: CGFloat = 300) {
        guard thumbnails[image.id] == nil, !failed.contains(image.id), tasks[image.id] == nil else { return }

        tasks[image.id] = Task { [weak self] in
            guard let self else { return }
            await self.semaphore.wait()
            defer { Task { await self.semaphore.signal() } }

            if Task.isCancelled { return }

            do {
                let thumbnail = try await self.downloadThumbnail(url: image.url, maxPixelSize: maxPixelSize, isSVG: image.isSVG)
                if Task.isCancelled { return }
                self.thumbnails[image.id] = thumbnail
            } catch {
                if !Task.isCancelled {
                    self.failed.insert(image.id)
                }
            }
            self.tasks[image.id] = nil
        }
    }

    func requestFullImage(for pageImage: PageImage, maxPixelSize: CGFloat = 2048) {
        let id = pageImage.id
        guard fullImages[id] == nil, fullImageTasks[id] == nil else { return }

        fullImageTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.fullImageSemaphore.wait()
            defer { Task { await self.fullImageSemaphore.signal() } }

            if !Task.isCancelled,
               let decoded = try? await self.downloadThumbnail(url: pageImage.url, maxPixelSize: maxPixelSize, isSVG: pageImage.isSVG) {
                self.fullImages[id] = decoded
            }
            self.fullImageTasks[id] = nil
        }
    }

    func cancel(for imageID: Int) {
        tasks[imageID]?.cancel()
        tasks[imageID] = nil
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        fullImageTasks.values.forEach { $0.cancel() }
        fullImageTasks.removeAll()
    }

    private func downloadThumbnail(url: URL, maxPixelSize: CGFloat, isSVG: Bool) async throws -> UIImage {
        let (data, _) = try await session.data(from: url)

        if isSVG {
            return try SVGRasterizer.rasterize(data: data, maxPixelSize: maxPixelSize)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageLoadError.decodeFailed
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoadError.decodeFailed
        }

        return UIImage(cgImage: cgImage)
    }
}

enum ImageLoadError: Error {
    case decodeFailed
}

/// Simple async semaphore used to cap concurrent thumbnail downloads,
/// preventing the "dozens of simultaneous requests" slowdown seen in the original app.
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.value = limit
    }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}
