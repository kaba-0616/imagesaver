import SwiftUI
import Photos

/// One photo of a group, opened big -- and, unlike a single group's worth of
/// pages, the whole run of groups that was on screen when it opened, so
/// swiping past the last photo of one group carries straight into the next
/// instead of stopping there.
///
/// Pinch to zoom and double tap to come back; there is deliberately no pan.
/// TabView's paging and a DragGesture of our own fight over the same finger on
/// iOS 15, and which one wins is not something that can be settled from here --
/// `.scrollDisabled` is iOS 16, so SwiftUI offers no way to hold the paging
/// still while a drag is in progress. The extension's fullscreen view has run
/// on real devices for the same reason and in the same shape.
struct DuplicatePreviewView: View {

    @ObservedObject var scanner: DuplicateScanner

    /// One page: which group a photo belongs to, and the photo itself.
    /// `groupID` is what lets the "≠" tile in the filmstrip know which whole
    /// group to reject, and what lets the pager land back inside the right
    /// group's run of pages after one is removed.
    private struct Page {
        let groupID: Int
        let member: PhotoFingerprint
    }

    /// Copied in when the tile was tapped, so the run of groups cannot
    /// re-order under the user if a file size lands while this is open --
    /// mutable only so a group can be dropped from it the moment "≠" removes
    /// that group everywhere else.
    @State private var groups: [DuplicateGroup]
    let onClose: () -> Void

    @StateObject private var loader = PreviewImageLoader()
    @State private var index: Int
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var dragOffset: CGFloat = 0
    /// A rejection outcome that was not simply "done" (busy, over the pair
    /// limit, a failed write) has nowhere else to surface on this fullscreen
    /// screen, so it gets this instead of the grid's inline message text.
    @State private var toast: String?

    private var pages: [Page] {
        groups.flatMap { group in group.displayOrder.map { Page(groupID: group.id, member: $0) } }
    }

    init(scanner: DuplicateScanner,
         groups: [DuplicateGroup],
         startGroupIndex: Int,
         startMemberIndex: Int,
         onClose: @escaping () -> Void) {
        self.scanner = scanner
        self.onClose = onClose
        _groups = State(initialValue: groups)

        let groupIndex = min(max(startGroupIndex, 0), max(groups.count - 1, 0))
        var flat = 0
        for group in groups[..<groupIndex] { flat += group.displayOrder.count }
        let memberCount = groups.indices.contains(groupIndex) ? groups[groupIndex].displayOrder.count : 0
        flat += min(max(startMemberIndex, 0), max(memberCount - 1, 0))
        _index = State(initialValue: flat)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(dismissOpacity)
            pager
                .offset(y: dragOffset)
            VStack(spacing: 0) {
                topBar
                if let toast {
                    Text(toast)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
                filmstrip
                bottomBar
            }
            .opacity(dismissOpacity)
        }
        .simultaneousGesture(dismissDrag)
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

    /// Swipe down to return to the grid, the same gesture the system Photos
    /// app uses. `simultaneousGesture` rather than `.gesture`: TabView's own
    /// paging gesture still needs first refusal on anything that could be a
    /// horizontal page swipe, and the two fighting over the same finger on
    /// iOS 15 is exactly the conflict the pinch/pan trade-off above exists to
    /// avoid. Gating on translation direction, not just distance, keeps a
    /// horizontal page swipe from ever moving this offset at all, so the two
    /// gestures read as independent instead of contested. Disabled while
    /// zoomed in, for the same reason panning is: a finger already busy
    /// positioning a zoomed photo should not also be closing it.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard scale <= 1.01,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let vertical = abs(value.translation.height) > abs(value.translation.width)
                if scale <= 1.01, vertical, value.translation.height > 120 {
                    onClose()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                }
            }
    }

    /// Fades the chrome and the black backdrop out as the photo is dragged
    /// away, so the gesture reads as "pulling the photo down toward the grid
    /// behind it" rather than a plain vertical scroll.
    private var dismissOpacity: Double {
        guard dragOffset > 0 else { return 1 }
        return Double(max(0, 1 - dragOffset / 400))
    }

    // MARK: - Pages

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(Array(pages.enumerated()), id: \.offset) { offset, _ in
                page(at: offset)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: indexDisplayMode))
    }

    /// Spelled out rather than written inline: a ternary inside `.page(...)`
    /// leaves the compiler inferring the style and the mode at once.
    private var indexDisplayMode: PageTabViewStyle.IndexDisplayMode {
        pages.count > 1 ? .automatic : .never
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

    /// One tile of the strip below: a page to jump to, the "≠" that rejects
    /// the group it trails, or the thin bar marking where one group's run of
    /// pages ends and the next begins.
    private enum FilmstripItem: Identifiable {
        case photo(pageIndex: Int, member: PhotoFingerprint)
        case reject(groupID: Int)
        case divider(afterGroupID: Int)

        var id: String {
            switch self {
            case .photo(let pageIndex, let member): return "photo-\(pageIndex)-\(member.localIdentifier)"
            case .reject(let groupID): return "reject-\(groupID)"
            case .divider(let groupID): return "divider-\(groupID)"
            }
        }
    }

    /// Every group's tiles followed by its own "≠", with a divider between
    /// one group's run and the next -- built fresh from `groups` each time
    /// `body` re-renders, which is exactly when a rejection may have removed
    /// one and this needs to look different anyway.
    private var filmstripItems: [FilmstripItem] {
        var items: [FilmstripItem] = []
        var pageIndex = 0
        for (offset, group) in groups.enumerated() {
            for member in group.displayOrder {
                items.append(.photo(pageIndex: pageIndex, member: member))
                pageIndex += 1
            }
            items.append(.reject(groupID: group.id))
            if offset < groups.count - 1 { items.append(.divider(afterGroupID: group.id)) }
        }
        return items
    }

    /// A page dot says which of twelve you are on. It does not say which
    /// twelve, and these are near-identical frames of one moment -- so the
    /// group itself goes along the bottom, current one lit. Spanning every
    /// group on screen rather than just the one open when this view was
    /// shown is what lets a swipe carry from one group's last photo straight
    /// into the next group's first.
    @ViewBuilder
    private var filmstrip: some View {
        if pages.count > 1 {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(filmstripItems) { item in
                                filmstripTile(item)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // A short group's row of tiles is narrower than the
                        // screen; without this it sits at the left edge
                        // instead of the middle a longer row would fill.
                        .frame(minWidth: geometry.size.width, alignment: .center)
                    }
                    .onChange(of: index) { moved in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(moved, anchor: .center)
                        }
                    }
                    // The .id(...) below tears this whole scroll view down
                    // and rebuilds it on every rejection, which resets the
                    // scroll offset to the leading edge -- onAppear puts it
                    // back on the current page instead of leaving the user
                    // looking at the start of the strip.
                    .onAppear {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                // A rejection changes which groups exist, not just which
                // page is selected -- LazyHStack reused the tiles from
                // before the removal rather than redrawing them, so the
                // strip sat frozen on the rejected group even once the main
                // photo had already moved on. Keying the whole scroll view
                // to the current lineup forces SwiftUI to throw the stale
                // one away instead of trying to patch it in place.
                .id(groups.map(\.id))
            }
            .frame(height: 68)
            .background(Color.black.opacity(0.45))
        }
    }

    @ViewBuilder
    private func filmstripTile(_ item: FilmstripItem) -> some View {
        switch item {
        case .photo(let pageIndex, let member):
            let current = pageIndex == index
            let chosen = scanner.selected.contains(member.localIdentifier)
            AssetThumbnail(identifier: member.localIdentifier, side: 52)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(current ? Color.accentColor
                                              : (chosen ? Color.white.opacity(0.8) : Color.clear),
                                      lineWidth: current ? 3 : 2)
                )
                .opacity(current ? 1 : 0.5)
                .contentShape(Rectangle())
                .onTapGesture { index = pageIndex }
                .id(pageIndex)
        case .reject(let groupID):
            Button {
                rejectAndAdvance(groupID)
            } label: {
                Text("≠")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 52)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(4)
            }
        case .divider:
            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 1, height: 40)
        }
    }

    /// "≠" pressed on a group's tile: the whole group goes, the same
    /// decision `DuplicateGroupCard`'s own reject button records, but without
    /// leaving fullscreen to do it. Landing the pager back at the group that
    /// used to follow this one keeps a straight run through "not this one
    /// either" presses feeling continuous instead of jumping to page one.
    private func rejectAndAdvance(_ groupID: Int) {
        guard let removedIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = groups[removedIndex]
        Task {
            let outcome = await scanner.reject(group)
            switch outcome {
            case .done, .listChanged:
                let targetGroupID = groups[(removedIndex + 1)...].first?.id
                    ?? groups[..<removedIndex].last?.id
                // Splitting this into "move the selection" then, after a
                // delay, "shrink the page count" (build99-102) did land
                // correctly, but it made the filmstrip visibly happen in two
                // separate beats -- scroll ahead, then a moment later the
                // rejected group's tiles vanish and it re-centers. What
                // actually left TabView(.page) frozen in the first place was
                // an *animated* transition trying to change the selection
                // and the data source at once; turning the animation off for
                // this one update is the direct fix, and it lets both
                // changes land together again as a single instant swap.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    groups.remove(at: removedIndex)
                    if let targetGroupID,
                       let newPage = pages.firstIndex(where: { $0.groupID == targetGroupID }) {
                        index = newPage
                    } else {
                        index = min(index, max(pages.count - 1, 0))
                    }
                }
                if groups.isEmpty { onClose() }
            case .busy, .groupTooLarge, .storeFull, .failed:
                let shown = outcome.describe(success: nil)
                toast = shown
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if toast == shown { toast = nil }
            }
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Button("閉じる") { onClose() }
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
            Spacer()
            if pages.count > 1 {
                Text("\(index + 1) / \(pages.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        // An overlay rather than a third HStack slot: "閉じる" and the page
        // count are different widths, and only an overlay keeps this block
        // centered on the screen regardless of that difference.
        .overlay(centerInfo)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.45))
    }

    @ViewBuilder
    private var centerInfo: some View {
        if let member = currentMember {
            VStack(spacing: 1) {
                Text(PhotoScanFormat.dayTime(member.creationDate))
                    .font(.caption)
                    .foregroundColor(.white)
                Text(detailLine(member))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.75))
                if let name = scanner.details[member.localIdentifier]?.originalFilename {
                    Text(name)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        // The extension at the end is what tells two
                        // otherwise-identical filenames apart (HEIC vs JPG
                        // from the same shot), so the truncation has to
                        // leave the tail alone.
                        .truncationMode(.middle)
                }
            }
            // Capped short of the full width so three lines of text never
            // reach far enough to sit under "閉じる" or the page count on
            // either side.
            .frame(maxWidth: 180)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let member = currentMember {
            HStack {
                Spacer()
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
        guard index >= 0, index < pages.count else { return nil }
        return pages[index].member
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
