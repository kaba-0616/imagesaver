import Photos
import SwiftUI

/// The margin-trim screen: scans the library for photos with a detectable
/// uniform-color margin (letterbox/pillarbox bars, or a border on all four
/// sides) and lets the user trim them, one at a time or in bulk. A separate
/// page from "写真の重複を整理" on purpose -- this judges one photo at a
/// time, not a relationship between photos, and mixing the two would make
/// neither screen's tab picker mean anything simple.
/// A snapshot of the candidates open when a card is tapped, plus which one
/// was tapped -- lets `MarginCropPreviewView` swipe through the whole run
/// without reflecting every scanner mutation (an applied/skipped candidate)
/// back into the list this screen is browsing mid-swipe.
private struct PreviewTarget: Identifiable {
    let items: [MarginCropCandidate]
    let startIndex: Int
    var id: String { items[startIndex].id }
}

struct MarginCropFinderView: View {

    @StateObject private var scanner = MarginCropScanner()
    @State private var selected: Set<String> = []
    @State private var busyIdentifiers: Set<String> = []
    // Blocks the whole grid's hit testing (not just the busy card's own
    // buttons) for the duration of any skip/apply -- single or bulk. Without
    // this, `LazyVGrid`'s position-based view reuse means a tap resolving
    // just as another card's mutation removes an item from `scanner.
    // candidates` can bind to whatever candidate has since slid into that
    // screen slot, opening a different photo than the one actually tapped.
    @State private var isMutatingGrid = false
    @State private var showingLevelPicker = false
    @State private var levelDisplay = Double(MarginLevel.stored())
    @State private var message: String?
    @State private var preview: PreviewTarget?
    @State private var showingSettings = false
    @State private var showingLog = false

    var body: some View {
        content
            .navigationTitle("写真の余白を整理")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                levelDisplay = Double(scanner.level)
                if scanner.phase == .idle,
                   scanner.access == .authorized || scanner.access == .limited {
                    scanner.scan()
                }
            }
            .onDisappear { PhotoScanLog.shared.flush() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingLevelPicker = true } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(scanner.phase != .ready)
                    .popover(isPresented: $showingLevelPicker) { levelPicker }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .fullScreenCover(item: $preview) { target in
                MarginCropPreviewView(scanner: scanner, items: target.items, startIndex: target.startIndex) {
                    preview = nil
                }
            }
            .sheet(isPresented: $showingSettings) {
                settingsSheet
            }
            .sheet(isPresented: $showingLog) {
                PhotoScanLogSheet(log: PhotoScanLog.shared) { showingLog = false }
            }
    }

    private var settingsSheet: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("「トリミングしない」として除外中")
                        Spacer()
                        Text("\(scanner.skippedCount)枚")
                            .foregroundColor(.secondary)
                    }
                    Button("除外をすべて解除") {
                        Task {
                            let outcome = await scanner.clearSkipped()
                            if outcome == .done { scanner.scan() }
                        }
                    }
                    .disabled(scanner.skippedCount == 0)
                }
                Section {
                    Button("ログ") {
                        showingSettings = false
                        showingLog = true
                    }
                }
                Section {
                    NavigationLink("診断: 写真を選んで判定値を見る") {
                        MarginDiagnosticView()
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { showingSettings = false }
                }
            }
        }
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

    private var accessRequest: some View {
        VStack(spacing: 16) {
            Text("余白のある写真を見つけるために、写真ライブラリへのアクセスが必要です。")
                .multilineTextAlignment(.center)
            Button("写真へのアクセスを許可する") { Task { await scanner.requestAccess() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private var accessRefused: some View {
        VStack(spacing: 12) {
            Text("写真へのアクセスが許可されていません。")
            Button("設定アプリを開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding(32)
    }

    @ViewBuilder
    private var library: some View {
        switch scanner.phase {
        case .idle:
            Color.clear.onAppear { scanner.scan() }
        case .counting:
            VStack(spacing: 12) {
                ProgressView()
                Text("写真を数えています…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(32)
        case .scanning(let done, let total, let remaining):
            VStack(spacing: 12) {
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    .padding(.horizontal, 48)
                Text("\(done) / \(total) 枚")
                    .font(.footnote)
                Text(remainingText(remaining))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(32)
        case .ready:
            results
        }
    }

    private func remainingText(_ remaining: TimeInterval?) -> String {
        guard let remaining else { return "残り時間を見積もっています…" }
        return PhotoScanFormat.remaining(remaining)
    }

    private var results: some View {
        Group {
            if scanner.candidates.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    grid
                    bottomBar
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("余白のある写真は見つかりませんでした")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(scanner.candidates) { candidate in
                    card(candidate)
                }
            }
            .padding(16)
        }
        .allowsHitTesting(!isMutatingGrid)
    }

    private func card(_ candidate: MarginCropCandidate) -> some View {
        let isSelected = selected.contains(candidate.id)
        let isBusy = busyIdentifiers.contains(candidate.id)
        return VStack(spacing: 6) {
            ZStack(alignment: .top) {
                AssetThumbnail(identifier: candidate.localIdentifier, side: 150, generation: 0)
                    .cornerRadius(8)
                    .onTapGesture {
                        let items = scanner.candidates
                        guard let startIndex = items.firstIndex(where: { $0.id == candidate.id }) else { return }
                        preview = PreviewTarget(items: items, startIndex: startIndex)
                    }
                HStack {
                    Button { toggle(candidate) } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(isSelected ? .accentColor : .white)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                    Spacer()
                    // "しない" used to be a second text button under the
                    // thumbnail, easy to misread next to "トリミング" -- an
                    // ✕ in the corner (the same idea as a dismissible card)
                    // reads as "not this one" without needing a label at all.
                    Button { Task { await skip(candidate) } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                }
                .padding(6)
            }
            .disabled(isBusy)
            Button("トリミング") { Task { await apply(candidate) } }
                .font(.caption.weight(.semibold))
                .disabled(isBusy)
        }
    }

    private func toggle(_ candidate: MarginCropCandidate) {
        if selected.contains(candidate.id) {
            selected.remove(candidate.id)
        } else {
            selected.insert(candidate.id)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await skipSelected() }
                } label: {
                    Text("選択した\(selected.count)枚をトリミングしない")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(selected.isEmpty)

                Button {
                    Task { await applySelected() }
                } label: {
                    Text("トリミング")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(12)
        .background(.bar)
    }

    func apply(_ candidate: MarginCropCandidate) async {
        isMutatingGrid = true
        busyIdentifiers.insert(candidate.id)
        let outcome = await scanner.apply(candidate)
        busyIdentifiers.remove(candidate.id)
        selected.remove(candidate.id)
        message = outcome.describe()
        isMutatingGrid = false
    }

    func skip(_ candidate: MarginCropCandidate) async {
        isMutatingGrid = true
        busyIdentifiers.insert(candidate.id)
        _ = await scanner.skip(candidate)
        busyIdentifiers.remove(candidate.id)
        selected.remove(candidate.id)
        isMutatingGrid = false
    }

    private func applySelected() async {
        isMutatingGrid = true
        let targets = scanner.candidates.filter { selected.contains($0.id) }
        var succeeded = 0
        var failed = 0
        var cancelled = 0
        for candidate in targets {
            switch await scanner.apply(candidate) {
            case .done: succeeded += 1
            case .cancelled: cancelled += 1
            case .failed: failed += 1
            }
        }
        selected.removeAll()
        // PHPhotosErrorDomain 3303/3302 (unresolved, see plan notes) means a
        // real bulk run can fail on some photos while succeeding on others --
        // each failure is already logged individually by `scanner.apply`, so
        // this summary only needs to tell the user how the run broke down,
        // not why.
        message = "成功\(succeeded)件 / 失敗\(failed)件"
            + (cancelled > 0 ? " / キャンセル\(cancelled)件" : "")
            + " (全\(targets.count)件)"
        isMutatingGrid = false
    }

    private func skipSelected() async {
        isMutatingGrid = true
        let targets = scanner.candidates.filter { selected.contains($0.id) }
        var succeeded = 0
        for candidate in targets {
            if await scanner.skip(candidate) == .done { succeeded += 1 }
        }
        selected.removeAll()
        message = "\(succeeded) / \(targets.count)枚を「トリミングしない」にしました"
        isMutatingGrid = false
    }

    // MARK: - Level

    private var levelValue: Int { MarginLevel.clamp(Int(levelDisplay.rounded())) }

    private var levelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("検出の厳しさ")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(levelValue)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: $levelDisplay,
                   in: Double(MarginLevel.range.lowerBound)...Double(MarginLevel.range.upperBound),
                   step: 1)
            HStack(spacing: 8) {
                Text("ゆるい")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(MarginLevel.detail(for: levelValue))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text("厳しい")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
            if levelValue != scanner.level {
                Text("表示中の結果はレベル\(scanner.level)のものです")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            Button("この設定で再スキャン") {
                scanner.commitLevel(levelValue)
                showingLevelPicker = false
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 280)
    }
}
