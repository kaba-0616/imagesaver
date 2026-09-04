import SwiftUI

/// One group of photographs the scan believes are the same picture.
///
/// Tapping a photo opens it; selecting is the circle in its corner. Two
/// separate targets on purpose -- this is a screen for choosing what to
/// delete, and a mis-tap that silently changes the selection is the one
/// mistake that cannot be taken back afterwards.
struct DuplicateGroupCard: View {

    let group: DuplicateGroup
    /// Position within the tab's list, 1-based. The label on its own repeats
    /// "似ている写真" on every card with nothing to tell one from another in
    /// conversation ("あの組" means nothing); a number gives each card a
    /// name a person can actually refer back to.
    let number: Int
    let selected: Set<String>
    let details: [String: AssetDetail]
    let thumbnailGeneration: Int
    let showsCheckboxes: Bool
    let onToggle: (String) -> Void
    let onSelectGroup: () -> Void
    let onDeselectGroup: () -> Void
    let onReject: () -> Void
    let onOpen: (Int) -> Void

    /// Wider than build 69's 88pt: the date and the file size are the two
    /// things that say which copy is the original, and neither fits on 88.
    private let side: CGFloat = 110
    /// Past this many members, a card would otherwise grow to thousands of
    /// points tall and bury every card after it -- collapsed to a handful of
    /// rows until asked to show the rest.
    private let collapsedLimit = 24
    @State private var showingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if group.hasRejectedPair { rejectedBadge }
            if !group.croppedIdentifiers.isEmpty { croppedBadge }
            strip
            if !group.isCleanedUp { actions }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if group.isCleanedUp {
                Text("クリーンアップ完了\(number)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.green)
            } else {
                Text("\(group.kind.label)\(number)")
                    .font(.subheadline.weight(.semibold))
            }
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            // Nothing left to compare against once only one photo remains.
            if !group.isCleanedUp { rejectButton }
        }
    }

    private var subtitle: String {
        var text = "\(group.members.count)枚"
        if let total = PhotoScanFormat.size(group.totalBytes) { text += " · \(total)" }
        return text
    }

    /// Nothing is deleted or hidden for good by this, so it is deliberately
    /// not styled as a destructive action.
    private var rejectButton: some View {
        Button(action: onReject) {
            // The glyph itself rather than an SF Symbol: this is the one place
            // a missing symbol name would leave the button unlabelled.
            Text("≠ 別々の写真")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var rejectedBadge: some View {
        Label("以前「違う」とした写真が含まれます", systemImage: "clock.arrow.circlepath")
            .font(.caption2)
            .foregroundColor(.orange)
    }

    /// Minimal on purpose: which tile is the trimmed one is already visible
    /// from the "残す候補" caption in the strip below. This just says why.
    private var croppedBadge: some View {
        Label("上下がトリミングされた写真を検知", systemImage: "crop")
            .font(.caption2)
            .foregroundColor(.blue)
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button(allChosen ? "選択を外す" : "1枚残して選択") {
                if allChosen { onDeselectGroup() } else { onSelectGroup() }
            }
            .font(.caption)
            // The bulk action never ticks a favourite, so on a group whose
            // every deletable member is one there is nothing for this button
            // to do. A button that looks live and does nothing when pressed
            // reads as the app being broken.
            .disabled(nothingToSelect)
        }
    }

    /// True when the only photos this card would offer for deletion are all
    /// favourites.
    private var nothingToSelect: Bool {
        !allChosen && group.suggestedDelete.allSatisfy(\.isFavorite)
    }

    // MARK: - Tiles

    /// A burst can be a handful of frames or, at the extreme end, hundreds --
    /// a horizontal scroll hid where one row ended and the next began, and a
    /// row that wraps reads as what it is: one group, several photos.
    private var strip: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side), spacing: 8)],
                     alignment: .leading, spacing: 8) {
                ForEach(visibleIndexedMembers, id: \.member.localIdentifier) { index, member in
                    tile(member, at: index)
                }
            }
            if group.members.count > collapsedLimit {
                Button(showingAll ? "折りたたむ" : "あと\(group.members.count - collapsedLimit)枚を表示") {
                    showingAll.toggle()
                }
                .font(.caption)
            }
        }
    }

    /// Oldest first: the strip and the fullscreen swipe order it feeds into
    /// are meant to read like a timeline, independent of which photo quality
    /// ranking picked as 残す候補.
    private var indexedMembers: [(index: Int, member: PhotoFingerprint)] {
        Array(group.displayOrder.enumerated()).map { ($0.offset, $0.element) }
    }

    private var visibleIndexedMembers: [(index: Int, member: PhotoFingerprint)] {
        let all = indexedMembers
        guard !showingAll, all.count > collapsedLimit else { return all }
        return Array(all.prefix(collapsedLimit))
    }

    private func tile(_ member: PhotoFingerprint, at index: Int) -> some View {
        let identifier = member.localIdentifier
        let chosen = selected.contains(identifier)
        return VStack(spacing: 3) {
            AssetThumbnail(identifier: identifier, side: side, generation: thumbnailGeneration)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 3)
                )
                .overlay(alignment: .top) { dateStrip(member) }
                .overlay(alignment: .topLeading) { favouriteBadge(member) }
                .overlay(alignment: .bottomLeading) { cloudBadge(identifier) }
                .contentShape(Rectangle())
                .onTapGesture { onOpen(index) }
                // Added last so it sits above the tap target below it.
                .overlay(alignment: .topTrailing) {
                    if showsCheckboxes { checkButton(identifier, chosen: chosen) }
                }
            caption(member)
        }
        .frame(width: side)
    }

    /// The single most useful thing on the tile: a 2023 original and the 2026
    /// re-save this app made of it are otherwise identical to look at.
    private func dateStrip(_ member: PhotoFingerprint) -> some View {
        Text(PhotoScanFormat.day(member.creationDate))
            .font(.system(size: 9))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedCorner())
    }

    @ViewBuilder
    private func favouriteBadge(_ member: PhotoFingerprint) -> some View {
        if member.isFavorite {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(.yellow)
                .background(Circle().fill(Color.black.opacity(0.4)))
                .padding(3)
        }
    }

    @ViewBuilder
    private func cloudBadge(_ identifier: String) -> some View {
        if details[identifier]?.isLocallyAvailable == false {
            Image(systemName: "icloud")
                .font(.system(size: 11))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .padding(4)
        }
    }

    private func checkButton(_ identifier: String, chosen: Bool) -> some View {
        Button { onToggle(identifier) } label: {
            ZStack {
                Circle().fill(chosen ? Color.accentColor : Color.black.opacity(0.45))
                Circle().strokeBorder(Color.white, lineWidth: 1.5)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 24, height: 24)
            // 24 plus the padding is a 32pt target, comfortably over the 28
            // this needs to be to hit reliably.
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Always two lines, the second blank when it does not apply. A grid row
    /// sizes itself to its tallest cell and then centres shorter ones in it --
    /// so a caption that only sometimes carries a second line left the
    /// thumbnail above it sitting at a different height than its neighbours.
    private func caption(_ member: PhotoFingerprint) -> some View {
        let isKeep = member.localIdentifier == group.suggestedKeep.localIdentifier
        return VStack(spacing: 0) {
            Text(PhotoScanFormat.pixels(width: member.width, height: member.height))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(sizeText(member))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(isKeep ? "残す候補" : " ")
                .font(.system(size: 8))
                .foregroundColor(.green)
                .opacity(isKeep ? 1 : 0)
        }
    }

    /// The byte size when it is known. Never a zero: a size that could not be
    /// read is not a small file, and the pixel dimensions above already cover
    /// the case where nothing else is available.
    private func sizeText(_ member: PhotoFingerprint) -> String {
        PhotoScanFormat.size(member.byteCount ?? details[member.localIdentifier]?.byteCount) ?? "サイズ不明"
    }

    /// Favourites are left out, because the button never picks them: judged
    /// over everything the label would still read "1枚残して選択" on a group
    /// whose only unchosen member is a favourite, and pressing it would then
    /// do nothing at all.
    private var allChosen: Bool {
        let offered = group.suggestedDelete.filter { !$0.isFavorite }
        return !offered.isEmpty
            && offered.allSatisfy { selected.contains($0.localIdentifier) }
    }
}

/// Rounds only where the strip meets the rounded corners of the thumbnail.
private struct RoundedCorner: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: 4)
    }
}
