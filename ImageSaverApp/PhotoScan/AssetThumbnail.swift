import Foundation
import SwiftUI
import Photos

/// One tile. The image lives in the tile's own state, so scrolling a tile away
/// releases it -- the same discipline the extension's grid needs, for the same
/// reason: a screen of these is the only place this app holds bitmaps.
struct AssetThumbnail: View {
    let identifier: String
    let side: CGFloat

    @State private var image: UIImage?

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
        .task(id: identifier) {
            guard image == nil else { return }
            let scale = UIScreen.main.scale
            let target = CGSize(width: side * scale, height: side * scale)
            for await candidate in AssetThumbnailLoader.images(for: identifier, target: target) {
                image = candidate
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
