import SwiftUI
import Photos

struct DuplicateFinderView: View {

    @StateObject private var scanner = DuplicateScanner()
    @State private var selected: Set<String> = []
    @State private var confirmingDelete = false
    @State private var resultMessage: String?

    var body: some View {
        content
            .navigationTitle("写真の重複を整理")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch scanner.access {
        case .authorized, .limited:
            library
        case .notDetermined:
            accessRequest
        default:
            accessRefused
        }
    }

    // MARK: - Permission

    private var accessRequest: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("重複を探すには写真を読み取る必要があります")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("保存だけなら「追加のみ」で足ります。この画面を使うときだけ、すべての写真へのアクセスを許可してください。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("写真へのアクセスを許可する") {
                Task { await scanner.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private var accessRefused: some View {
        VStack(spacing: 16) {
            Text("写真へのアクセスが許可されていません")
                .font(.headline)
            Button("設定アプリを開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding(32)
    }

    // MARK: - Scan

    @ViewBuilder
    private var library: some View {
        switch scanner.phase {
        case .idle:
            startPrompt
        case .scanning(let done, let total):
            scanning(done: done, total: total)
        case .grouping:
            ProgressView("照合中…")
        case .ready:
            results
        }
    }

    private var startPrompt: some View {
        VStack(spacing: 16) {
            Text("ライブラリ全体を調べて、同じ写真と似ている写真をまとめます。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if scanner.access == .limited {
                Text("「選択した写真のみ」の設定なので、許可した写真だけが対象になります。")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
            Button("調べる") { scanner.scan() }
                .buttonStyle(.borderedProminent)
            Text("写真は読み取るだけです。削除はこの後の画面で選んだものだけ、iOSの確認を挟んでから行われます。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func scanning(done: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                .padding(.horizontal, 48)
            Text(total > 0 ? "\(done) / \(total) 枚" : "写真を数えています…")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(32)
    }

    // MARK: - Results

    private var results: some View {
        VStack(spacing: 0) {
            if scanner.groups.isEmpty {
                emptyResult
            } else {
                groupList
            }
            bottomBar
        }
        .confirmationDialog("選択した\(selected.count)枚を削除しますか？",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("削除する", role: .destructive) {
                Task { await runDelete() }
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("「最近削除した項目」に30日残ります。iCloud写真がオンの場合は他の端末からも消えます。")
        }
    }

    private var emptyResult: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("重複は見つかりませんでした")
                .foregroundColor(.secondary)
            sensitivityPicker
                .padding(.horizontal, 32)
            Text(scanner.report)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                sensitivityPicker
                ForEach(scanner.groups) { group in
                    DuplicateGroupCard(group: group, selected: $selected)
                }
                Text(scanner.report)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding()
        }
    }

    private var sensitivityPicker: some View {
        VStack(spacing: 4) {
            Picker("判定の強さ", selection: $scanner.sensitivity) {
                ForEach(Sensitivity.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)
            Text(scanner.sensitivity.detail)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let resultMessage {
                Text(resultMessage)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("1枚残して全選択") { selectAllButBest() }
                    .disabled(scanner.groups.isEmpty)
                Button("解除") { selected.removeAll() }
                    .disabled(selected.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Text("削除 (\(selected.count))")
                }
                .disabled(selected.isEmpty)
            }
            .font(.footnote)
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: - Actions

    /// Never picks a favourite, and never picks every member of a group: the
    /// bulk action is the one most likely to be used without looking, so it is
    /// the one that has to be conservative.
    private func selectAllButBest() {
        var next = selected
        for group in scanner.groups {
            for member in group.suggestedDelete where !member.isFavorite {
                next.insert(member.localIdentifier)
            }
        }
        selected = next
    }

    private func runDelete() async {
        let outcome = await scanner.delete(selected)
        switch outcome {
        case .success(let count):
            selected.removeAll()
            resultMessage = count > 0
                ? "\(count)枚を削除しました。「最近削除した項目」に30日残ります。"
                : nil
        case .failure:
            resultMessage = "削除は行われませんでした。"
        }
    }
}

private struct DuplicateGroupCard: View {

    let group: DuplicateGroup
    @Binding var selected: Set<String>

    private let side: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            strip
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var header: some View {
        HStack {
            Text(group.kind.label)
                .font(.subheadline.weight(.semibold))
            Text("\(group.members.count)枚")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button(allChosen ? "選択を外す" : "1枚残して選択") { toggleGroup() }
                .font(.caption)
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(group.members, id: \.localIdentifier) { member in
                    tile(member)
                }
            }
        }
        .frame(height: side + 20)
    }

    private func tile(_ member: PhotoFingerprint) -> some View {
        let chosen = selected.contains(member.localIdentifier)
        return VStack(spacing: 3) {
            AssetThumbnail(identifier: member.localIdentifier, side: side)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(chosen ? Color.red : Color.clear, lineWidth: 3)
                )
                .overlay(alignment: .topTrailing) { badge(for: member, chosen: chosen) }
                .contentShape(Rectangle())
                .onTapGesture { toggle(member) }
            Text(caption(for: member))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func badge(for member: PhotoFingerprint, chosen: Bool) -> some View {
        if chosen {
            Image(systemName: "trash.circle.fill")
                .foregroundColor(.red)
                .background(Circle().fill(Color.white))
                .padding(3)
        } else if member.isFavorite {
            Image(systemName: "star.circle.fill")
                .foregroundColor(.yellow)
                .background(Circle().fill(Color.black.opacity(0.4)))
                .padding(3)
        }
    }

    private func caption(for member: PhotoFingerprint) -> String {
        let size = "\(member.width)×\(member.height)"
        if member.localIdentifier == group.suggestedKeep.localIdentifier {
            return "残す候補 " + size
        }
        return size
    }

    private var allChosen: Bool {
        !group.suggestedDelete.isEmpty
            && group.suggestedDelete.allSatisfy { selected.contains($0.localIdentifier) }
    }

    private func toggleGroup() {
        if allChosen {
            for member in group.members { selected.remove(member.localIdentifier) }
        } else {
            for member in group.suggestedDelete where !member.isFavorite {
                selected.insert(member.localIdentifier)
            }
        }
    }

    private func toggle(_ member: PhotoFingerprint) {
        if selected.contains(member.localIdentifier) {
            selected.remove(member.localIdentifier)
        } else {
            selected.insert(member.localIdentifier)
        }
    }
}
