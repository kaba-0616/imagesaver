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
    /// Which URL each measurement came from. An upgraded image is previewed
    /// through the page's small copy, so a measurement taken there describes a
    /// different file from the one that will be saved.
    @Published private(set) var measuredFrom: [Int: URL] = [:]

    /// The pixel size of the file this image will actually save, once
    /// something has measured it. Nil while the only measurement on hand came
    /// from previewing a smaller copy.
    func trueSize(of image: PageImage) -> CGSize? {
        guard let size = pixelSizes[image.id] else { return nil }
        guard image.renderedURL == nil || measuredFrom[image.id] == image.url else { return nil }
        return size
    }

    private func record(_ pixelSize: CGSize?, for image: PageImage, from url: URL) {
        guard let pixelSize else { return }
        // A measurement of the original outranks one of the preview copy, and
        // the two downloads can finish in either order.
        if measuredFrom[image.id] == image.url, url != image.url { return }
        measuredFrom[image.id] = url
        pixelSizes[image.id] = pixelSize
    }

    /// Tiles currently on screen. Their thumbnails are never evicted: a cell
    /// has already had its onAppear, so dropping its image would leave a blank
    /// tile with nothing left to trigger a reload.
    private var onScreen: Set<Int> = []
    /// Least recently used first.
    private var thumbnailOrder: [Int] = []
    private var fullImageOrder: [Int] = []

    /// Sized against the extension's allowance, not the device's RAM. A page
    /// of 300 images scrolled end to end would otherwise hold every decoded
    /// tile at once, and the system's answer to that is to kill the process --
    /// which from outside looks like the share sheet closing by itself.
    private let thumbnailBudget = 32 * 1024 * 1024
    /// Fullscreen shows one image; its neighbours are worth keeping for a
    /// swipe back and no more. At 2048px each is around 11MB.
    private let fullImageLimit = 3

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

    private var memoryWarningObserver: NSObjectProtocol?

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.purge() }
        }
    }

    deinit {
        // The extension's process is reused across share-sheet invocations, so
        // an observer left behind here accumulates one per run.
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func markOnScreen(_ id: Int, _ visible: Bool) {
        if visible { onScreen.insert(id) } else { onScreen.remove(id) }
    }

    /// The system has said it is short of memory. An extension that ignores
    /// that is killed rather than asked a second time.
    func purge() {
        RunOutcome.note("メモリ警告を受けて解放")
        while fullImageOrder.count > 1 {
            fullImages[fullImageOrder.removeFirst()] = nil
        }
        trimThumbnails(to: 0)
    }

    private func storeThumbnail(_ image: UIImage, for id: Int) {
        thumbnails[id] = image
        thumbnailOrder.removeAll { $0 == id }
        thumbnailOrder.append(id)
        trimThumbnails(to: thumbnailBudget)
    }

    private func storeFullImage(_ image: UIImage, for id: Int) {
        fullImages[id] = image
        fullImageOrder.removeAll { $0 == id }
        fullImageOrder.append(id)
        while fullImageOrder.count > fullImageLimit {
            fullImages[fullImageOrder.removeFirst()] = nil
        }
    }

    private func trimThumbnails(to budget: Int) {
        var total = thumbnailOrder.reduce(0) { $0 + bytes(of: thumbnails[$1]) }
        var index = 0
        while total > budget, index < thumbnailOrder.count {
            let id = thumbnailOrder[index]
            if onScreen.contains(id) {
                index += 1
                continue
            }
            total -= bytes(of: thumbnails[id])
            thumbnails[id] = nil
            thumbnailOrder.remove(at: index)
        }
    }

    private func bytes(of image: UIImage?) -> Int {
        guard let cgImage = image?.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

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
                let (thumbnail, pixelSize, from) = try await self.download(
                    image,
                    preferring: image.renderedURL ?? image.url,
                    maxPixelSize: maxPixelSize)
                if Task.isCancelled { return }
                self.storeThumbnail(thumbnail, for: image.id)
                self.record(pixelSize, for: image, from: from)
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
               let (decoded, pixelSize, from) = try? await self.download(
                   pageImage,
                   preferring: pageImage.url,
                   maxPixelSize: maxPixelSize) {
                self.storeFullImage(decoded, for: id)
                self.record(pixelSize, for: pageImage, from: from)
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
    ) async throws -> (image: UIImage, pixelSize: CGSize?, from: URL) {
        do {
            let got = try await downloadThumbnail(url: first, maxPixelSize: maxPixelSize, isSVG: image.isSVG)
            return (got.image, got.pixelSize, first)
        } catch {
            let other = (first == image.url) ? image.renderedURL : image.url
            guard let other, other != first else { throw error }
            let got = try await downloadThumbnail(url: other, maxPixelSize: maxPixelSize, isSVG: image.isSVG)
            return (got.image, got.pixelSize, other)
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
