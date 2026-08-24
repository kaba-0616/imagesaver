import UIKit
import ImageIO

@MainActor
final class ImageLoader: ObservableObject {

    // Deliberately not a singleton: the extension process is reused across
    // pages, and a shared cache keyed by index would show the previous page's
    // images in the new page's tiles.

    @Published private(set) var thumbnails: [Int: UIImage] = [:]
    @Published private(set) var fullImages: [Int: UIImage] = [:]
    @Published private(set) var failed: Set<Int> = []
    /// True pixel dimensions read from the downloaded file, which are usually
    /// more accurate than the layout sizes the page's DOM reported.
    @Published private(set) var pixelSizes: [Int: CGSize] = [:]

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
                // Previewing costs whatever the page itself paid: an
                // upgraded URL points at a multi-megabyte original, and a
                // screenful of those is the slow, memory-hungry load this app
                // exists to avoid.
                let (thumbnail, pixelSize) = try await self.download(
                    image,
                    preferring: image.renderedURL ?? image.url,
                    maxPixelSize: maxPixelSize)
                if Task.isCancelled { return }
                self.thumbnails[image.id] = thumbnail
                if let pixelSize {
                    self.pixelSizes[image.id] = pixelSize
                }
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
               let (decoded, pixelSize) = try? await self.download(
                   pageImage,
                   preferring: pageImage.url,
                   maxPixelSize: maxPixelSize) {
                self.fullImages[id] = decoded
                if let pixelSize {
                    self.pixelSizes[id] = pixelSize
                }
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

    /// Tries one URL and, if the image has an alternate, the other. The two
    /// differ only in which copy of the same picture they name, so either
    /// answers the request.
    private func download(
        _ image: PageImage,
        preferring first: URL,
        maxPixelSize: CGFloat
    ) async throws -> (image: UIImage, pixelSize: CGSize?) {
        do {
            return try await downloadThumbnail(url: first, maxPixelSize: maxPixelSize, isSVG: image.isSVG)
        } catch {
            let other = (first == image.url) ? image.renderedURL : image.url
            guard let other, other != first else { throw error }
            return try await downloadThumbnail(url: other, maxPixelSize: maxPixelSize, isSVG: image.isSVG)
        }
    }

    private func downloadThumbnail(
        url: URL,
        maxPixelSize: CGFloat,
        isSVG: Bool
    ) async throws -> (image: UIImage, pixelSize: CGSize?) {
        let (data, _) = try await session.data(from: url)

        if isSVG {
            let rendered = try SVGRasterizer.rasterize(data: data, maxPixelSize: maxPixelSize)
            return (rendered, nil)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageLoadError.decodeFailed
        }

        // Read the full-resolution dimensions from the header before downsampling.
        var pixelSize: CGSize?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: width, height: height)
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

        return (UIImage(cgImage: cgImage), pixelSize)
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
