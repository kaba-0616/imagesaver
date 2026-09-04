import Photos
import SwiftUI

/// The margin-trim screen: scans the library for photos with a detectable
/// uniform-color margin (letterbox/pillarbox bars, or a border on all four
/// sides) and lets the user trim them, one at a time or in bulk. A separate
/// page from "写真の重複を整理" on purpose -- this judges one photo at a
/// time, not a relationship between photos, and mixing the two would make
/// neither screen's tab picker mean anything simple.
struct MarginCropFinderView: View {

    @StateObject private var scanner = MarginCropScanner()
    @State private var selected: Set<String> = []
    @State private var busyIdentifiers: Set<String> = []
    @State private var showingLevelPicker = false
    @State private var levelDisplay = Double(MarginLevel.stored())
    @State private var message: String?
    @State private var preview: MarginCropCandidate?

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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingLevelPicker = true } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(scanner.phase != .ready)
                    .popover(isPresented: $showingLevelPicker) { levelPicker }
                }
            }
            .fullScreenCover(item: $preview) { candidate in
                MarginCropPreviewView(scanner: scanner, candidate: candidate) {
                    preview = nil
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
        case .scanning(let done, let total):
            VStack(spacing: 12) {
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    .padding(.horizontal, 48)
                Text("\(done) / \(total) 枚")
                    .font(.footnote)
            }
            .padding(32)
        case .ready:
            results
        }
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

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(scanner.candidates) { candidate in
                    card(candidate)
                }
            }
            .padding(12)
        }
    }

    private func card(_ candidate: MarginCropCandidate) -> some View {
        let isSelected = selected.contains(candidate.id)
        let isBusy = busyIdentifiers.contains(candidate.id)
        return VStack(spacing: 6) {
            ZStack(alignment: .top) {
                AssetThumbnail(identifier: candidate.localIdentifier, side: 150, generation: 0)
                    .cornerRadius(8)
                    .onTapGesture { preview = candidate }
                HStack {
                    Button { toggle(candidate) } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(isSelected ? .accentColor : .white)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                    Spacer()
                    Text(candidate.badgeLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                .padding(6)
            }
            HStack(spacing: 8) {
                Button("トリミング") { Task { await apply(candidate) } }
                    .font(.caption.weight(.semibold))
                Button("しない") { Task { await skip(candidate) } }
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
            Button {
                Task { await applySelected() }
            } label: {
                Text("選択した\(selected.count)枚をまとめてトリミング")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
        }
        .padding(12)
        .background(.bar)
    }

    func apply(_ candidate: MarginCropCandidate) async {
        busyIdentifiers.insert(candidate.id)
        let outcome = await scanner.apply(candidate)
        busyIdentifiers.remove(candidate.id)
        selected.remove(candidate.id)
        message = outcome.describe()
    }

    func skip(_ candidate: MarginCropCandidate) async {
        busyIdentifiers.insert(candidate.id)
        _ = await scanner.skip(candidate)
        busyIdentifiers.remove(candidate.id)
        selected.remove(candidate.id)
    }

    private func applySelected() async {
        let targets = scanner.candidates.filter { selected.contains($0.id) }
        var succeeded = 0
        for candidate in targets {
            if await scanner.apply(candidate) == .done { succeeded += 1 }
        }
        selected.removeAll()
        message = "\(succeeded) / \(targets.count)枚をトリミングしました"
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
