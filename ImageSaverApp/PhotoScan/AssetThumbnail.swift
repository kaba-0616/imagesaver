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
            image = await AssetThumbnailLoader.image(
                for: identifier,
                target: CGSize(width: side * scale, height: side * scale))
        }
    }
}

enum AssetThumbnailLoader {

    /// Resumes exactly once, whichever of the callback and the deadline gets
    /// there first. A checked continuation resumed twice is a crash, and one
    /// never resumed leaves the tile waiting for good.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UIImage?, Never>?

        init(_ continuation: CheckedContinuation<UIImage?, Never>) {
            self.continuation = continuation
        }

        func settle(_ image: UIImage?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: image)
        }
    }

    /// Only ever used for the deadline below, which never blocks it.
    private static let timer = DispatchQueue(label: "jp.kaba.imagesaver.thumbnail",
                                             qos: .userInitiated)

    /// Nothing here waits on a semaphore. A card full of tiles asks for all of
    /// them at once, and a blocking wait per tile ties up one thread each for
    /// as long as the slowest of them takes -- which is how a grid of pictures
    /// turns into the stall this app was written to get away from.
    static func image(for identifier: String, target: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let gate = Gate(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                // Armed before anything that can take its time, fetchAssets
                // included: a fetch that does not come back would otherwise
                // leave the continuation with nothing left to resume it, and
                // the tile sits at "loading" for the life of the screen. It
                // cannot fire twice into the continuation, and it holds
                // nothing while it waits.
                timer.asyncAfter(deadline: .now() + 8) { gate.settle(nil) }

                let found = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                guard let asset = found.firstObject else {
                    gate.settle(nil)
                    return
                }

                let options = PHImageRequestOptions()
                // fastFormat calls back exactly once, with whatever the system
                // already has. Network access stays off: a tile is not worth
                // the user's data, and the card marks iCloud photos anyway.
                options.deliveryMode = .fastFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false

                PHImageManager.default().requestImage(for: asset,
                                                      targetSize: target,
                                                      contentMode: .aspectFill,
                                                      options: options) { image, _ in
                    gate.settle(image)
                }
            }
        }
    }
}
