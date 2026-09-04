import Photos
import SwiftUI

/// Full-screen before/after check for a run of candidates, reached by
/// tapping a card. Swipeable left/right to move on to the next candidate
/// without closing and reopening -- the same continuous-browsing idea
/// `DuplicatePreviewView` uses for duplicate groups, adapted for a flat list
/// instead of paged groups.
///
/// "Before" shows the detected margin as a red overlay on the original;
/// "after" shows a locally-cropped preview of the same photo -- a display-
/// only render, not what actually gets written (`MarginCropScanner.apply`
/// redoes the crop from the full-resolution original independently, through
/// `PHContentEditingInput`, once the user actually confirms here).
struct MarginCropPreviewView: View {
    @ObservedObject var scanner: MarginCropScanner
    let onClose: () -> Void

    /// A mutable copy of the candidates open when this screen was
    /// presented -- `scanner.candidates` itself is left alone so the list
    /// behind this screen does not reflow mid-browse.
    @State private var pages: [MarginCropCandidate]
    @State private var index: Int
    /// Candidates whose "トリミングする"/"これはトリミングしない" has
    /// already been sent to the scanner but not yet actually removed from
    /// `pages` -- see `advance(from:)`. `TabView(.page)` on iOS is known
    /// (from this project's own `DuplicatePreviewView` history) to not
    /// reliably repaint a page-count change and a selection change made in
    /// the same state update, so the selection is always moved first, on
    /// its own, and the array is only shrunk afterward once the selection
    /// has already moved away from the removed page.
    @State private var processedIDs: Set<String> = []
    @State private var toast: String?
    @State private var busy = false
    @State private var showingAfter = false
    /// Which background the photo sits against. A white margin can hide
    /// against a light backdrop and a black one against a dark backdrop --
    /// switching this is how a check can actually see either edge clearly.
    @State private var backgroundIsWhite = false

    init(scanner: MarginCropScanner, items: [MarginCropCandidate], startIndex: Int, onClose: @escaping () -> Void) {
        self.scanner = scanner
        self.onClose = onClose
        _pages = State(initialValue: items)
        _index = State(initialValue: startIndex)
    }

    private var candidate: MarginCropCandidate? { pages.indices.contains(index) ? pages[index] : nil }

    var body: some View {
        ZStack {
            (backgroundIsWhite ? Color.white : Color.black).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                TabView(selection: $index) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { i, page in
                        MarginCropPhotoPage(candidate: page, showingAfter: showingAfter)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
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
        .onChange(of: pages.isEmpty) { empty in if empty { onClose() } }
    }

    /// The one color everything in this overlay chrome uses -- flips with
    /// the background so text and icons stay legible against either.
    private var foreground: Color { backgroundIsWhite ? .black : .white }
    private var dimBackground: Color { (backgroundIsWhite ? Color.black : Color.white).opacity(0.15) }

    private var topBar: some View {
        HStack {
            Button("閉じる") { onClose() }
                .foregroundColor(foreground)
            Spacer()
            modeToggle
            Spacer()
            Button {
                backgroundIsWhite.toggle()
            } label: {
                Image(systemName: backgroundIsWhite ? "circle.righthalf.filled" : "circle.lefthalf.filled")
                    .font(.title3)
                    .foregroundColor(foreground)
            }
        }
        .padding(16)
    }

    /// A plain `Picker(.segmented)` on a black backdrop is what prompted
    /// this: the system control paints its unselected label in the system's
    /// own label color, which on a dark background renders as barely-visible
    /// dark-on-dark. This draws both states explicitly instead, so switching
    /// `backgroundIsWhite` keeps both labels readable rather than just one.
    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeButton(title: "トリミング前", isOn: !showingAfter) { showingAfter = false }
            modeButton(title: "トリミング後", isOn: showingAfter) { showingAfter = true }
        }
        .padding(2)
        .background(dimBackground)
        .cornerRadius(8)
    }

    private func modeButton(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(isOn ? (backgroundIsWhite ? .white : .black) : foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isOn ? foreground : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
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
            .tint(foreground)

            Button {
                Task { await runApply() }
            } label: {
                Text("トリミングする")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .disabled(busy || candidate == nil)
    }

    private func runSkip() async {
        guard let candidate else { return }
        busy = true
        let outcome = await scanner.skip(candidate)
        busy = false
        await advance(candidate, outcome: outcome)
    }

    private func runApply() async {
        guard let candidate else { return }
        busy = true
        let outcome = await scanner.apply(candidate)
        busy = false
        await advance(candidate, outcome: outcome)
    }

    /// Moves off the just-processed candidate immediately (pure selection
    /// change) so the swipe view feels instant, then -- once the backend
    /// call has actually confirmed -- shrinks `pages` for real. On failure,
    /// the optimistic move is rolled back and the candidate stays put with
    /// an error toast, mirroring `DuplicatePreviewView.rejectAndAdvance`.
    private func advance(_ candidate: MarginCropCandidate, outcome: MarginCropScanner.ApplyOutcome) async {
        guard outcome == .done else {
            toast = outcome.describe()
            return
        }
        let previousIndex = index
        processedIDs.insert(candidate.id)
        if let next = nextUnprocessedIndex() {
            index = next
        }
        if let removeAt = pages.firstIndex(where: { $0.id == candidate.id }) {
            let stayOnID = pages.indices.contains(index) ? pages[index].id : nil
            pages.remove(at: removeAt)
            processedIDs.remove(candidate.id)
            if let stayOnID, let newIndex = pages.firstIndex(where: { $0.id == stayOnID }) {
                index = newIndex
            } else {
                index = min(previousIndex, max(pages.count - 1, 0))
            }
        }
    }

    private func nextUnprocessedIndex() -> Int? {
        guard !pages.isEmpty else { return nil }
        for offset in 1...pages.count {
            let candidateIndex = (index + offset) % pages.count
            if !processedIDs.contains(pages[candidateIndex].id) { return candidateIndex }
        }
        return nil
    }
}

/// One page of the swipeable preview: loads and shows a single candidate's
/// photo, either with the detected margin highlighted or a locally-cropped
/// preview. Split out from `MarginCropPreviewView` because each page needs
/// its own independently-loaded image, keyed to its own candidate.
private struct MarginCropPhotoPage: View {
    let candidate: MarginCropCandidate
    let showingAfter: Bool

    @State private var image: UIImage?

    var body: some View {
        Group {
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
        .task(id: candidate.id) { load() }
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
