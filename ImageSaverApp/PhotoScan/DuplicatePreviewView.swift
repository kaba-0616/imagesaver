import SwiftUI
import Photos

/// One group, opened big.
///
/// Pinch to zoom and double tap to come back; there is deliberately no pan.
/// TabView's paging and a DragGesture of our own fight over the same finger on
/// iOS 15, and which one wins is not something that can be settled from here --
/// `.scrollDisabled` is iOS 16, so SwiftUI offers no way to hold the paging
/// still while a drag is in progress. The extension's fullscreen view has run
/// on real devices for the same reason and in the same shape.
struct DuplicatePreviewView: View {

    @ObservedObject var scanner: DuplicateScanner

    /// Copied in when the tile was tapped, so the pages cannot re-order under
    /// the user if the file sizes land while this is open.
    let members: [PhotoFingerprint]
    let onClose: () -> Void

    @StateObject private var loader = PreviewImageLoader()
    @State private var index: Int
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    init(scanner: DuplicateScanner,
         members: [PhotoFingerprint],
         startIndex: Int,
         onClose: @escaping () -> Void) {
        self.scanner = scanner
        self.members = members
        self.onClose = onClose
        let last = max(members.count - 1, 0)
        _index = State(initialValue: min(max(startIndex, 0), last))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                filmstrip
                bottomBar
            }
        }
        .onAppear { loadCurrent() }
        .onChange(of: index) { _ in
            scale = 1
            lastScale = 1
            loadCurrent()
        }
        // The one bitmap this screen holds goes back when it closes. Nothing
        // else in the app keeps a full size image around.
        .onDisappear { loader.cancel() }
    }

    // MARK: - Pages

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(Array(members.enumerated()), id: \.element.localIdentifier) { offset, _ in
                page(at: offset)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: indexDisplayMode))
    }

    /// Spelled out rather than written inline: a ternary inside `.page(...)`
    /// leaves the compiler inferring the style and the mode at once.
    private var indexDisplayMode: PageTabViewStyle.IndexDisplayMode {
        members.count > 1 ? .automatic : .never
    }

    /// Only the page in front of the user draws a photo. The ones either side
    /// stay black on purpose: holding three full size images to make a swipe
    /// look smoother is exactly the trade this app exists to avoid.
    @ViewBuilder
    private func page(at offset: Int) -> some View {
        ZStack {
            Color.black
            if offset == index { currentPhoto }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var currentPhoto: some View {
        if let image = loader.image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1, min(lastScale * value, 5))
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        scale = 1
                        lastScale = 1
                    }
                }
        } else if let failure = loader.failure {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(failure)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(.white)
            .padding(32)
        } else {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                if let fraction = loader.downloadFraction {
                    Text("iCloudから取得中 \(Int(fraction * 100))%")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
    }

    // MARK: - Filmstrip

    /// A page dot says which of twelve you are on. It does not say which
    /// twelve, and these are near-identical frames of one moment -- so the
    /// group itself goes along the bottom, current one lit.
    @ViewBuilder
    private var filmstrip: some View {
        if members.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(Array(members.enumerated()),
                                id: \.element.localIdentifier) { offset, member in
                            filmstripTile(member, at: offset).id(offset)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(height: 68)
                .background(Color.black.opacity(0.45))
                .onChange(of: index) { moved in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(moved, anchor: .center)
                    }
                }
            }
        }
    }

    private func filmstripTile(_ member: PhotoFingerprint, at offset: Int) -> some View {
        let current = offset == index
        let chosen = scanner.selected.contains(member.localIdentifier)
        return AssetThumbnail(identifier: member.localIdentifier, side: 52)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(current ? Color.accentColor
                                          : (chosen ? Color.white.opacity(0.8) : Color.clear),
                                  lineWidth: current ? 3 : 2)
            )
            .opacity(current ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { index = offset }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Button("閉じる") { onClose() }
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
            Spacer()
            if members.count > 1 {
                Text("\(index + 1) / \(members.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.45))
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let member = currentMember {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PhotoScanFormat.day(member.creationDate))
                        .font(.footnote)
                        .foregroundColor(.white)
                    Text(detailLine(member))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.75))
                }
                Spacer(minLength: 8)
                selectButton(member)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.45))
        }
    }

    private func selectButton(_ member: PhotoFingerprint) -> some View {
        let chosen = scanner.selected.contains(member.localIdentifier)
        return Button {
            scanner.toggle(member.localIdentifier)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(chosen ? Color.accentColor : Color.white.opacity(0.15))
                    Circle().strokeBorder(Color.white, lineWidth: 2)
                    if chosen {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 30, height: 30)
                Text(chosen ? "選択中" : "選択")
                    .font(.footnote)
                    .foregroundColor(.white)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private var currentMember: PhotoFingerprint? {
        guard index >= 0, index < members.count else { return nil }
        return members[index]
    }

    private func detailLine(_ member: PhotoFingerprint) -> String {
        var text = PhotoScanFormat.pixels(width: member.width, height: member.height)
        let bytes = member.byteCount ?? scanner.details[member.localIdentifier]?.byteCount
        if let size = PhotoScanFormat.size(bytes) { text += "  " + size }
        return text
    }

    private func loadCurrent() {
        guard let member = currentMember else { return }
        loader.load(member.localIdentifier, target: targetSize)
    }

    /// Screen sized, in pixels. Enough that the picture is sharp at 1x and
    /// still recognisable pinched in, without asking Photos to decode an
    /// original that can be forty megapixels.
    private var targetSize: CGSize {
        let bounds = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

/// The flags Photos puts in the info dictionary of a result.
///
/// Free standing, and deliberately not a member of the loader below: the result
/// handler runs wherever Photos decides, and anything it calls has to be
/// reachable from outside the main actor. `info?[key]` is avoided throughout --
/// optional chaining on a dictionary subscript leaves a double optional, and
/// `!= nil` on one of those is true whenever the dictionary itself is present.
private enum PreviewResultInfo {

    static func flag(_ info: [AnyHashable: Any]?, _ key: String) -> Bool {
        guard let info else { return false }
        return (info[key] as? NSNumber)?.boolValue ?? false
    }

    static func hasError(_ info: [AnyHashable: Any]?) -> Bool {
        guard let info else { return false }
        return info[PHImageErrorKey] != nil
    }
}

/// Holds exactly one photo, for exactly as long as it is being looked at.
///
/// Nothing here waits on a semaphore. Cancelling a Photos request can leave the
/// result handler never called at all, and a blocking wait mixed with that
/// stalls a thread until it times out -- which is what the thumbnail loader
/// gets away with only because its requests are small and never cancelled.
@MainActor
final class PreviewImageLoader: ObservableObject {

    @Published private(set) var image: UIImage?
    @Published private(set) var failure: String?
    /// Only while iCloud is actually sending something. A photo whose original
    /// is on the device never reports progress at all.
    @Published private(set) var downloadFraction: Double?

    private var identifier: String?
    private var requestID: PHImageRequestID?
    /// Bumped by anything that ends interest in the current request, so a late
    /// callback from the previous page cannot paint over this one.
    private var token = 0

    func load(_ wanted: String, target: CGSize) {
        guard wanted != identifier else { return }
        cancel()
        identifier = wanted

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [wanted],
                                              options: nil).firstObject else {
            failure = "この写真が見つかりませんでした"
            // Nothing was loaded, so nothing is being held: leaving the
            // identifier set would make the guard above turn every later
            // attempt at this page into a no-op.
            identifier = nil
            return
        }

        token += 1
        let current = token

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        // On for this screen alone. Everywhere else in the app network access
        // stays off so a scan cannot spend the user's data; here the user has
        // tapped one photo and asked to see it.
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction, error, _, _ in
            // Called on a serial queue of Photos' choosing -- not this one, and
            // not necessarily the same one twice. The error is turned into its
            // text here so that nothing but plain values crosses over.
            let text = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.updateProgress(fraction, failure: text, token: current)
            }
        }

        // Stored out here, never from inside the handler: with .opportunistic
        // the first callback can run synchronously, before requestImage has
        // returned, and an id read from in there is one that does not exist
        // yet.
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            // All three are `let`: a Task's closure is @Sendable, and even
            // reading a captured `var` from inside one is an error rather than
            // a warning.
            let degraded = PreviewResultInfo.flag(info, PHImageResultIsDegradedKey)
            let cancelled = PreviewResultInfo.flag(info, PHImageCancelledKey)
            let failed = PreviewResultInfo.hasError(info)
            Task { @MainActor [weak self] in
                self?.receive(image,
                              degraded: degraded,
                              cancelled: cancelled,
                              failed: failed,
                              token: current)
            }
        }
    }

    func cancel() {
        token += 1
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
        requestID = nil
        identifier = nil
        image = nil
        failure = nil
        downloadFraction = nil
    }

    private func updateProgress(_ fraction: Double, failure text: String?, token: Int) {
        guard token == self.token else { return }
        if let text {
            failure = "iCloudから取得できませんでした: " + text
            downloadFraction = nil
            return
        }
        downloadFraction = fraction < 1 ? fraction : nil
    }

    private func receive(_ delivered: UIImage?,
                         degraded: Bool,
                         cancelled: Bool,
                         failed: Bool,
                         token: Int) {
        guard token == self.token else { return }
        // A degraded image is still worth showing: it is the difference between
        // a placeholder and the photograph while iCloud is still sending.
        if let delivered { image = delivered }
        guard !degraded || cancelled || failed else { return }

        downloadFraction = nil
        requestID = nil
        if image == nil && !cancelled {
            failure = "この写真を読み込めませんでした"
        }
    }
}
