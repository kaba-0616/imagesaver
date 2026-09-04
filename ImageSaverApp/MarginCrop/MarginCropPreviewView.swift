import Photos
import SwiftUI

/// Full-screen before/after check for one candidate, reached by tapping its
/// card. "Before" shows the detected margin as a red overlay on the original;
/// "after" shows a locally-cropped preview of the same photo -- a display-
/// only render, not what actually gets written (`MarginCropScanner.apply`
/// redoes the crop from the full-resolution original independently, through
/// `PHContentEditingInput`, once the user actually confirms here).
struct MarginCropPreviewView: View {
    @ObservedObject var scanner: MarginCropScanner
    let candidate: MarginCropCandidate
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var showingAfter = false
    @State private var toast: String?
    @State private var busy = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                photo
                Spacer(minLength: 0)
                if let toast {
                    Text(toast)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding(.bottom, 8)
                }
                bottomBar
            }
        }
        .onAppear { load() }
    }

    private var topBar: some View {
        HStack {
            Button("閉じる") { onClose() }
                .foregroundColor(.white)
            Spacer()
            Picker("", selection: $showingAfter) {
                Text("トリミング前").tag(false)
                Text("トリミング後").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
        .padding(16)
    }

    @ViewBuilder
    private var photo: some View {
        if let image {
            if showingAfter {
                if let cropped = croppedImage(image) {
                    Image(uiImage: cropped)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else {
                    Text("プレビューを作成できませんでした")
                        .foregroundColor(.white)
                }
            } else {
                GeometryReader { geometry in
                    let fit = fitSize(for: image.size, in: geometry.size)
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                        marginOverlay(fitSize: fit)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .padding()
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    private func fitSize(for imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// Two overlapping overlays -- one for the vertical edges, one for the
    /// horizontal -- since a four-sided margin needs both at once and neither
    /// alone can paint an L-shaped region without covering the surviving
    /// corner too.
    @ViewBuilder
    private func marginOverlay(fitSize: CGSize) -> some View {
        let margin = candidate.margin
        let topFrac = CGFloat(margin.top) / CGFloat(max(candidate.height, 1))
        let bottomFrac = CGFloat(margin.bottom) / CGFloat(max(candidate.height, 1))
        let leftFrac = CGFloat(margin.left) / CGFloat(max(candidate.width, 1))
        let rightFrac = CGFloat(margin.right) / CGFloat(max(candidate.width, 1))
        VStack(spacing: 0) {
            Color.red.opacity(0.4).frame(height: fitSize.height * topFrac)
            Spacer(minLength: 0)
            Color.red.opacity(0.4).frame(height: fitSize.height * bottomFrac)
        }
        .frame(width: fitSize.width, height: fitSize.height)
        HStack(spacing: 0) {
            Color.red.opacity(0.4).frame(width: fitSize.width * leftFrac)
            Spacer(minLength: 0)
            Color.red.opacity(0.4).frame(width: fitSize.width * rightFrac)
        }
        .frame(width: fitSize.width, height: fitSize.height)
    }

    /// `candidate.margin`/`cropRect` are in the asset's own full pixel space;
    /// this preview image is very likely a smaller fetch, so the crop rect is
    /// rescaled to whatever pixel size actually came back.
    private func croppedImage(_ source: UIImage) -> UIImage? {
        guard let cgImage = source.cgImage, candidate.width > 0, candidate.height > 0 else { return nil }
        let scaleX = CGFloat(cgImage.width) / CGFloat(candidate.width)
        let scaleY = CGFloat(cgImage.height) / CGFloat(candidate.height)
        let rect = candidate.cropRect
        let scaledRect = CGRect(x: rect.origin.x * scaleX, y: rect.origin.y * scaleY,
                                 width: rect.width * scaleX, height: rect.height * scaleY).integral
        guard let cropped = cgImage.cropping(to: scaledRect) else { return nil }
        return UIImage(cgImage: cropped, scale: source.scale, orientation: source.imageOrientation)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await runSkip() }
            } label: {
                Text("これはトリミングしない")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button {
                Task { await runApply() }
            } label: {
                Text("トリミングする")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .disabled(busy)
    }

    private func runSkip() async {
        busy = true
        let outcome = await scanner.skip(candidate)
        busy = false
        if outcome == .done { onClose() } else { toast = outcome.describe() }
    }

    private func runApply() async {
        busy = true
        let outcome = await scanner.apply(candidate)
        busy = false
        if outcome == .done { onClose() } else { toast = outcome.describe() }
    }

    private func load() {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.localIdentifier], options: nil)
        guard let asset = found.firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let target = CGSize(width: 1600, height: 1600)
        PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                              options: options) { result, _ in
            // Photos does not guarantee this callback lands on the main
            // thread, and `image` is a SwiftUI @State property.
            guard let result else { return }
            DispatchQueue.main.async { self.image = result }
        }
    }
}
