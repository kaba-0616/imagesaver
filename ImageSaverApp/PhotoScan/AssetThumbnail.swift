import Foundation
import SwiftUI
import Photos

/// One tile. The image lives in the tile's own state, so scrolling a tile away
/// releases it -- the same discipline the extension's grid needs, for the same
/// reason: a screen of these is the only place this app holds bitmaps.
struct AssetThumbnail: View {
    let identifier: String
    let side: CGFloat
    /// Bumped by `DuplicateScanner` each time a regroup lands new results --
    /// the only signal this view has that the asset behind `identifier`
    /// might have been edited in Photos since the last fetch. Folded into
    /// the `.task(id:)` key below so a regroup forces a refetch without
    /// needing to detect the edit itself.
    let generation: Int

    @State private var image: UIImage?
    @State private var loadedGeneration: Int?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: "\(identifier)#\(generation)") {
            guard loadedGeneration != generation else { return }
            let scale = UIScreen.main.scale
            let target = CGSize(width: side * scale, height: side * scale)

            // Network access stays off here (see AssetThumbnailLoader), so a
            // cloud-only asset Photos hasn't cached anything for yet simply
            // yields nothing before the 8s deadline. That used to still get
            // silently retried whenever this tile's view happened to be torn
            // down and rebuilt (scrolling off-screen and back, say) -- but
            // now that identity is kept stable on purpose (to stop
            // unrelated tiles flashing gray on a rejection), a tile that
            // fails once would otherwise stay blank forever. Retrying with
            // backoff here, for as long as this tile stays on screen, is
            // what catches the asset once it does become locally available
            // some other way (the user opened it fullscreen, say, which
            // does allow network access and downloads the original).
            var delay: UInt64 = 3_000_000_000
            while !Task.isCancelled {
                var received = false
                for await candidate in AssetThumbnailLoader.images(for: identifier, target: target) {
                    image = candidate
                    received = true
                }
                if received {
                    loadedGeneration = generation
                    return
                }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 60_000_000_000)
            }
        }
    }
}

enum AssetThumbnailLoader {

    /// Only ever used for the deadline below, which never blocks it.
    private static let timer = DispatchQueue(label: "jp.kaba.imagesaver.thumbnail",
                                             qos: .userInitiated)

    /// Nothing here waits on a semaphore. A card full of tiles asks for all of
    /// them at once, and a blocking wait per tile ties up one thread each for
    /// as long as the slowest of them takes -- which is how a grid of pictures
    /// turns into the stall this app was written to get away from.
    ///
    /// `.opportunistic` delivery: unlike the old `.fastFormat` (whatever
    /// Photos already has cached, once), this yields a quick low-quality
    /// preview first and then the properly resized version once Photos has
    /// rendered it -- which is what made list thumbnails look permanently
    /// blurry for a photo Photos had not already cached at this size. The
    /// stream yields once for the low-quality pass and again for the final
    /// one, then finishes; the 8s deadline guards against the final pass
    /// never arriving (an iCloud original with network access off).
    static func images(for identifier: String, target: CGSize) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let finishOnce = FinishOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                timer.asyncAfter(deadline: .now() + 8) { finishOnce.finish() }

                let found = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                guard let asset = found.firstObject else {
                    finishOnce.finish()
                    return
                }

                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false

                PHImageManager.default().requestImage(for: asset,
                                                      targetSize: target,
                                                      contentMode: .aspectFill,
                                                      options: options) { image, info in
                    if let image { continuation.yield(image) }
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if !isDegraded { finishOnce.finish() }
                }
            }
        }
    }

    /// `AsyncStream.Continuation.finish()` is safe to call more than once by
    /// itself, but the deadline timer and the image callback both hold a
    /// reference to this and either can fire first -- this just keeps that
    /// race from being reasoned about twice in two different places.
    private final class FinishOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<UIImage>.Continuation?

        init(_ continuation: AsyncStream<UIImage>.Continuation) {
            self.continuation = continuation
        }

        func finish() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.finish()
        }
    }
}
