import SwiftUI
import Photos

/// One photo of a group, opened big -- and, unlike a single group's worth of
/// pages, the whole run of groups that was on screen when it opened, so
/// swiping past the last photo of one group carries straight into the next
/// instead of stopping there.
///
/// Pinch to zoom, drag to pan once zoomed in, double tap to come back.
/// TabView's paging and a DragGesture of our own fight over the same finger on
/// iOS 15 with no reliable way to say which should win (`.scrollDisabled`,
/// the clean fix, is iOS 16) -- worked around in `currentPhoto` by masking
/// the pan gesture to `.subviews` (effectively absent) whenever the photo is
/// at 1x, so the pager's own swipe is never contested except while actually
/// zoomed in.
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
    /// Where a zoomed-in photo has been panned to, relative to centered.
    /// Reset alongside `scale` any time the photo goes back to fit-to-screen,
    /// since an offset with nothing zoomed in to justify it would just push
    /// the next photo off-center the moment a swipe changes `index`.
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var dragOffset: CGFloat = 0
    /// A rejection outcome that was not simply "done" (busy, over the pair
    /// limit, a failed write) has nowhere else to surface on this fullscreen
    /// screen, so it gets this instead of the grid's inline message text.
    @State private var toast: String?
    /// Groups hidden from the filmstrip the instant "≠" is pressed, before
    /// `scanner.reject` has even been asked -- `pages` (what the pager's
    /// page count is derived from) deliberately does not consult this, so
    /// pressing "≠" only ever changes `index`(a plain selection change) as
    /// far as the pager is concerned, while the filmstrip (which does
    /// consult this) updates in the very same instant. The group is only
    /// actually removed from `groups` once the rejection is confirmed; see
    /// `rejectAndAdvance`.
    @State private var hiddenGroupIDs: Set<Int> = []
    /// Center of the filmstrip's display window (see `filmstripWindow`) --
    /// only moved when a swipe carries `index` outside the current window,
    /// not on every swipe, so ordinary browsing never reshuffles the strip's
    /// `ForEach` and the smooth per-swipe `scrollTo` below keeps working
    /// exactly as before.
    @State private var filmstripWindowCenter: Int
    /// Which way the last real page change went, tracked so "≠" can carry
    /// the pager onward in that same direction. Rejecting a run of groups
    /// while swiping backward through them (browsing from the end of a
    /// long tab toward the front, say) used to always land on the group
    /// *after* the removed one regardless -- forward, against the direction
    /// being swiped -- so the position visibly lurched forward and had to
    /// be swiped back past again on every single rejection.
    @State private var browseDirection = 1
    @State private var lastKnownIndex: Int

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
        _filmstripWindowCenter = State(initialValue: flat)
        _lastKnownIndex = State(initialValue: flat)
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
        .onAppear {
            loadCurrent()
            prefetchNeighbors()
        }
        .onChange(of: index) { newIndex in
            if newIndex != lastKnownIndex {
                browseDirection = newIndex > lastKnownIndex ? 1 : -1
                lastKnownIndex = newIndex
            }
            scale = 1
            lastScale = 1
            panOffset = .zero
            lastPanOffset = .zero
            loadCurrent()
            prefetchNeighbors()
            // Recenters only when a swipe actually leaves the current
            // window -- ordinary browsing stays within it, so the strip's
            // `ForEach` set (and the smooth scrollTo below) is untouched.
            if !filmstripWindow.contains(newIndex) {
                filmstripWindowCenter = newIndex
            }
        }
        // The one bitmap this screen holds goes back when it closes. Nothing
        // else in the app keeps a full size image around -- the prefetch
        // below never holds one either, so there is nothing else to release.
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
    /// stay black unless `loader` already happens to have a bitmap cached for
    /// them -- which, thanks to the small LRU cache below and the neighbor
    /// warm-up in `prefetchNeighbors`, the immediate neighbor usually does.
    /// `TabView(.page)` composites the current and adjacent pages live during
    /// an interactive drag, not a snapshot, so this is what turns "the next
    /// photo slides in from black" into "the next photo is already sitting
    /// there, like the system Photos app" -- without holding more bitmaps at
    /// once than the cache already bounds.
    @ViewBuilder
    private func page(at offset: Int) -> some View {
        ZStack {
            Color.black
            if offset == index {
                currentPhoto
            } else if pages.indices.contains(offset),
                      let neighbor = loader.image(for: pages[offset].member.localIdentifier) {
                Image(uiImage: neighbor)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
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
                .offset(panOffset)
                // `including:` (a `GestureMask`) is what makes this coexist
                // with `TabView`'s own paging swipe on iOS 15 -- `.gesture`
                // alone would have this and the pager's internal one-finger
                // recognizer fighting over the same touch with no reliable
                // way to say which should win (`.scrollDisabled`, the clean
                // fix, is iOS 16+). Masked to `.subviews` while at 1x, this
                // drag recognizer does not exist as far as the pager is
                // concerned, so ordinary swiping between photos is completely
                // unaffected; only once zoomed in does it switch to `.all`
                // and start claiming the touch for panning instead.
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            panOffset = CGSize(width: lastPanOffset.width + value.translation.width,
                                               height: lastPanOffset.height + value.translation.height)
                        }
                        .onEnded { _ in
                            lastPanOffset = panOffset
                        },
                    including: scale > 1.01 ? .all : .subviews
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1, min(lastScale * value, 5))
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1.01 {
                                panOffset = .zero
                                lastPanOffset = .zero
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        scale = 1
                        lastScale = 1
                        panOffset = .zero
                        lastPanOffset = .zero
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

        // Identity is the photo itself, never `pageIndex` -- a group ahead
        // of this one being hidden or actually removed shifts every later
        // page's number, and an id that moved with it made ForEach treat
        // the tile as a brand new view, throwing away the `AssetThumbnail`
        // it already had a decoded image in and flashing gray while it
        // re-fetched. `pageIndex` is still carried as data for the tap
        // target below; it just isn't part of what makes a tile "the same
        // tile" from one render to the next.
        /// Shared with the scrollTo targets below, so a lookup by identifier
        /// always lands on the same string this case's `id` produces.
        static func photoID(_ identifier: String) -> String { "photo-\(identifier)" }

        var id: String {
            switch self {
            case .photo(_, let member): return Self.photoID(member.localIdentifier)
            case .reject(let groupID): return "reject-\(groupID)"
            case .divider(let groupID): return "divider-\(groupID)"
            }
        }
    }

    /// How many pages either side of `filmstripWindowCenter` the strip ever
    /// builds tiles for. Jumping straight to a page deep in a long run of
    /// groups (opening the last group of a library with thousands of
    /// photos, say) used to make the strip's initial `scrollTo` realize
    /// every tile between the very first page and that one -- each a real
    /// `AssetThumbnail` starting its own Photos fetch -- which is what made
    /// opening a far-off group visibly heavy and stuttery. Generous enough
    /// that ordinary browsing (a run of swipes in one sitting) essentially
    /// never reaches the edge and forces a recenter.
    private let filmstripWindowRadius = 150

    private var filmstripWindow: Range<Int> {
        let lower = max(0, filmstripWindowCenter - filmstripWindowRadius)
        let upper = min(pages.count, filmstripWindowCenter + filmstripWindowRadius + 1)
        return lower..<max(lower, upper)
    }

    /// Every group's tiles followed by its own "≠", with a divider between
    /// one group's run and the next -- built fresh from `groups` each time
    /// `body` re-renders, which is exactly when a rejection may have removed
    /// one and this needs to look different anyway. Restricted to groups
    /// that overlap `filmstripWindow`; a group is never split partway
    /// through, so its "≠" tile and the divider after it stay attached to
    /// the run of photos they belong to.
    ///
    /// A group in `hiddenGroupIDs` contributes no tiles at all -- pressed
    /// "≠" but not yet confirmed by `scanner.reject` -- while still being
    /// walked for its page count, so the numbering here never drifts from
    /// `pages`, which does not know about `hiddenGroupIDs` at all.
    private var filmstripItems: [FilmstripItem] {
        let window = filmstripWindow
        var items: [FilmstripItem] = []
        var pageIndex = 0
        for (offset, group) in groups.enumerated() {
            let groupPageCount = group.displayOrder.count
            defer { pageIndex += groupPageCount }
            guard !hiddenGroupIDs.contains(group.id) else { continue }
            guard (pageIndex..<(pageIndex + groupPageCount)).overlaps(window) else { continue }
            for (memberOffset, member) in group.displayOrder.enumerated() {
                items.append(.photo(pageIndex: pageIndex + memberOffset, member: member))
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
                        guard pages.indices.contains(moved) else { return }
                        let target = FilmstripItem.photoID(pages[moved].member.localIdentifier)
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                    // Restores the scroll position on the first appearance
                    // of this screen (there is no other reason for the
                    // offset to need resetting now that nothing below forces
                    // this view to be rebuilt).
                    .onAppear {
                        guard pages.indices.contains(index) else { return }
                        proxy.scrollTo(FilmstripItem.photoID(pages[index].member.localIdentifier),
                                       anchor: .center)
                    }
                }
                // No `.id(...)` on this container -- there used to be one
                // keyed on `groups.map(\.id)`, added back when a rejection
                // reliably left LazyHStack showing stale tiles unless the
                // whole scroll view was torn down and rebuilt. That staleness
                // traced back to `FilmstripItem.photo`'s id embedding
                // `pageIndex`: removing a group shifted every later page's
                // number, which changed every later tile's id at once and
                // was what LazyHStack handled badly. Now that identity is the
                // photo itself (see `FilmstripItem.id`) a real removal
                // doesn't touch any surviving tile's id at all -- `groups`
                // shrinking just drops the (already hidden, already
                // invisible) rejected tiles from `filmstripItems`, which
                // ForEach's ordinary diffing handles the same way it already
                // does for `hiddenGroupIDs`. Forcing a full rebuild here on
                // top of that only bought back the exact gray flash the
                // `hiddenGroupIDs` exclusion from `.id(...)` was written to
                // avoid, moved to land a beat later once `scanner.reject`
                // actually confirms.
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
            AssetThumbnail(identifier: member.localIdentifier, side: 52,
                           generation: scanner.thumbnailGeneration)
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
                // Same id `ForEach` already knows this tile by (see
                // `FilmstripItem.id`) -- keeping the two in sync is what
                // lets `scrollTo` below target this tile by the photo it
                // shows rather than by a page number that shifts under a
                // rejection.
                .id(item.id)
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
        // Whichever direction the user was actually swiping wins -- rejecting
        // a run of groups while browsing backward through them should keep
        // heading backward, not lurch forward to "the next one" every time
        // just because that used to be the only direction tried first.
        let forwardTarget = groups[(removedIndex + 1)...].first?.id
        let backwardTarget = groups[..<removedIndex].last?.id
        let targetGroupID = browseDirection < 0
            ? (backwardTarget ?? forwardTarget)
            : (forwardTarget ?? backwardTarget)
        let previousIndex = index

        // Instant, together: TabView(.page) only ever reliably repaints a
        // change to *either* its page count or its selection in one update,
        // never both -- every earlier attempt that changed `groups` and
        // `index` at once (or staggered them a beat apart) either froze the
        // main photo or made the filmstrip visibly lag behind it. Hiding the
        // group here leaves `pages` (what backs the pager) untouched, so
        // from TabView's point of view this is a plain selection change,
        // while the filmstrip -- which reads `hiddenGroupIDs` directly --
        // updates in the very same instant.
        hiddenGroupIDs.insert(groupID)
        if let targetGroupID, let newPage = pages.firstIndex(where: { $0.groupID == targetGroupID }) {
            index = newPage
        } else {
            index = min(index, max(pages.count - 1, 0))
        }
        let onlyGroupLeft = groups.count == 1

        Task {
            let outcome = await scanner.reject(group)
            switch outcome {
            case .done, .listChanged:
                // Nothing the user can see changes from here on -- the photo
                // already on screen and the strip's tiles are already
                // correct -- so folding the hide into a real removal is just
                // bookkeeping. Re-finding `index` by the photo it currently
                // points at (rather than doing arithmetic on the old
                // position) keeps this correct even if the user swiped
                // elsewhere during the round trip.
                let currentPage = pages[index]
                groups.remove(at: removedIndex)
                hiddenGroupIDs.remove(groupID)
                index = pages.firstIndex(where: {
                    $0.groupID == currentPage.groupID
                        && $0.member.localIdentifier == currentPage.member.localIdentifier
                }) ?? min(index, max(pages.count - 1, 0))
                if onlyGroupLeft { onClose() }
            case .busy, .groupTooLarge, .storeFull, .failed:
                hiddenGroupIDs.remove(groupID)
                index = previousIndex
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

    /// Warms Photos' own cache for the pages around `index` -- two either
    /// side, since swiping back to compare against an earlier photo is as
    /// likely here as swiping forward. A plain one-shot `requestImage` per
    /// neighbor, not `PHCachingImageManager`: the manager has no completion
    /// callback, so there would be no way to notice a cloud-only asset just
    /// finished downloading and clear its badge in the grid. The delivered
    /// image itself is discarded immediately -- this app still never holds
    /// more than the one bitmap `loader` keeps for the page on screen -- and
    /// nothing here needs releasing when the view closes, since nothing is
    /// retained beyond the request itself. Network access is allowed, same
    /// as `loadCurrent()`'s own request: the download this kicks off for a
    /// cloud-only photo is the whole point of prefetching it early.
    private func prefetchNeighbors() {
        let neighborIndices = [index - 2, index - 1, index + 1, index + 2]
            .filter { pages.indices.contains($0) }
        guard !neighborIndices.isEmpty else { return }
        let identifiers = neighborIndices.map { pages[$0].member.localIdentifier }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byIdentifier: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in byIdentifier[asset.localIdentifier] = asset }
        guard !byIdentifier.isEmpty else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let size = targetSize

        for identifier in identifiers {
            guard let asset = byIdentifier[identifier] else { continue }
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                                                  contentMode: .aspectFit,
                                                  options: options) { _, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded else { return }
                Task { @MainActor in
                    scanner.refreshLocalAvailability(identifier)
                }
            }
        }

        // The immediate neighbor only (±1, matching how much room the LRU
        // cache below actually has beyond the current page) also gets
        // warmed directly into `loader`'s own cache, at the same target size
        // `currentPhoto` displays at -- not the smaller one above -- so the
        // interactive drag has an actual bitmap to composite instead of
        // black the moment the user's finger starts moving, rather than
        // waiting for the swipe to settle and `loadCurrent` to catch up.
        for adjacent in [index - 1, index + 1] where pages.indices.contains(adjacent) {
            loader.warm(pages[adjacent].member.localIdentifier, target: targetSize)
        }
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
    /// The last few full-quality bitmaps this screen has actually finished
    /// loading, most-recently-used last. Flipping back and forth between a
    /// couple of photos to compare them used to throw the just-loaded image
    /// away and re-fetch it from scratch every time -- a black flash on
    /// every return trip even between only two photos -- since `load`
    /// unconditionally discarded whatever it held whenever the identifier
    /// changed. Capped at 3 (the current page plus one either side, matching
    /// how many pages the fullscreen viewer prefetches) so this never grows
    /// into the "hold every image" design this app deliberately avoids.
    private var cache: [String: UIImage] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 3

    /// A read-only peek at the cache -- never triggers a fetch. Lets the
    /// pager paint a neighboring page's actual photo (when it happens to
    /// already be cached) instead of leaving it black while the page next
    /// to the current one is on screen during an interactive swipe.
    func image(for identifier: String) -> UIImage? {
        cache[identifier]
    }

    /// Fetches straight into the cache without touching `image`,
    /// `identifier`, or `failure` -- those describe the page actually on
    /// screen, and a neighbor being warmed in the background must not
    /// interrupt or race with whatever `load` is doing for the current one.
    /// A no-op if the cache already has it or it's what's currently showing
    /// (which `load` itself keeps current in the cache already).
    func warm(_ wanted: String, target: CGSize) {
        guard cache[wanted] == nil, wanted != identifier else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [wanted],
                                              options: nil).firstObject else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(
            for: asset, targetSize: target, contentMode: .aspectFit, options: options
        ) { [weak self] image, info in
            guard let image else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !degraded else { return }
            Task { @MainActor in
                guard let self, self.cache[wanted] == nil else { return }
                self.cache[wanted] = image
                self.remember(wanted)
            }
        }
    }

    func load(_ wanted: String, target: CGSize) {
        guard wanted != identifier else { return }
        cancelRequest()
        identifier = wanted
        failure = nil
        downloadFraction = nil

        if let cached = cache[wanted] {
            image = cached
            remember(wanted)
            return
        }
        image = nil

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
                              token: current,
                              identifier: wanted)
            }
        }
    }

    /// Stops whatever is in flight without touching the cache -- used both
    /// at the top of `load` (a new page superseding an old request) and by
    /// `cancel` below.
    private func cancelRequest() {
        token += 1
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
        requestID = nil
    }

    /// Called when the fullscreen viewer itself closes -- releases every
    /// cached bitmap, not just the one on screen, since nothing needs to
    /// survive past this screen's lifetime.
    func cancel() {
        cancelRequest()
        identifier = nil
        image = nil
        failure = nil
        downloadFraction = nil
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func remember(_ identifier: String) {
        cacheOrder.removeAll { $0 == identifier }
        cacheOrder.append(identifier)
        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
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
                         token: Int,
                         identifier: String) {
        guard token == self.token else { return }
        // A degraded image is still worth showing: it is the difference between
        // a placeholder and the photograph while iCloud is still sending.
        if let delivered { image = delivered }
        guard !degraded || cancelled || failed else { return }

        downloadFraction = nil
        requestID = nil
        if !degraded, !cancelled, !failed, let final = image {
            cache[identifier] = final
            remember(identifier)
        }
        if image == nil && !cancelled {
            failure = "この写真を読み込めませんでした"
        }
    }
}
