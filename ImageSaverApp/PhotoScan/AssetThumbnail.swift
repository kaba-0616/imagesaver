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

    static func image(for identifier: String, target: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: load(identifier, target))
            }
        }
    }

    private static func load(_ identifier: String, _ target: CGSize) -> UIImage? {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = found.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        var result: UIImage?
        let waiter = DispatchSemaphore(value: 0)
        PHImageManager.default().requestImage(for: asset,
                                              targetSize: target,
                                              contentMode: .aspectFill,
                                              options: options) { image, _ in
            result = image
            waiter.signal()
        }
        _ = waiter.wait(timeout: .now() + 5)
        return result
    }
}
