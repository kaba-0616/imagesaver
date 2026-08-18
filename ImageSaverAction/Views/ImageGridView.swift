import SwiftUI

enum DisplayMode: String, CaseIterable {
    case grid = "グリッド"
    case fullscreen = "フルスクリーン"
}

enum SizeFilter: Int, CaseIterable, Identifiable {
    case all = 0
    case medium = 100
    case large = 300

    var id: Int { rawValue }

    /// Menu wording. The pixel threshold is kept as a hint so the tiers are
    /// not purely relative.
    var label: String {
        switch self {
        case .all: return "すべて表示"
        case .medium: return "小を除外 (100px未満)"
        case .large: return "中・小を除外 (300px未満)"
        }
    }
}

struct ImageGridView: View {
    let images: [PageImage]
    let pageTitle: String
    /// What the page-extraction script did and found. Nothing on the device can
    /// debug that script, so it reports on itself and the result lands here.
    let extractionLog: [String]
    let onClose: () -> Void

    @StateObject private var loader = ImageLoader()
    @StateObject private var photoSaver = PhotoSaver()

    @State private var selected: Set<Int> = []
    @State private var displayMode: DisplayMode = .grid
    @State private var sizeFilter: SizeFilter = .all
    /// Off by default: feed-style sites (Instagram and friends) keep images
    /// from unrelated posts in their payload, and including them makes the
    /// grid look like it scraped the wrong page.
    @State private var includeSourceOnly = false
    @State private var fullscreenIndex: Int = 0
    @State private var showLogSheet = false

    private var visibleImages: [PageImage] {
        images.filter { image in
            // Already-saved images drop out of the grid so it's obvious what is left to do.
            guard !photoSaver.savedImageIDs.contains(image.id) else { return false }
            guard includeSourceOnly || !image.isFromSourceOnly else { return false }
            guard sizeFilter != .all else { return true }
            let known = max(image.width, image.height)
            return known == 0 || known >= sizeFilter.rawValue
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 3)

    var body: some View {
        // No modal result popup: progress and outcome are shown inline in the
        // bottom status line, and details are available via the log sheet.
        mainContent
            .overlay(savingOverlay)
            .animation(.easeInOut(duration: 0.15), value: photoSaver.isSaving)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showLogSheet) {
                LogSheet(
                    extractionLog: extractionLog,
                    currentLog: photoSaver.log,
                    previousLog: PersistentLog.read()
                ) { showLogSheet = false }
            }
    }

    /// Shown while a save is in flight. Saving several full-size images takes
    /// long enough that the bottom status line alone reads as a frozen screen.
    @ViewBuilder
    private var savingOverlay: some View {
        if case .saving(let done, let total) = photoSaver.state {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()

                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.4)
                        .tint(.white)
                    Text("保存中 \(done)/\(total)")
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(white: 0.16))
                )
            }
            // Swallows taps so the selection cannot change mid-save.
            .contentShape(Rectangle())
            .onTapGesture {}
            .transition(.opacity)
        }
    }

    private var mainContent: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("表示", selection: $displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.black)
                .onAppear {
                    // Default unselected text is dark gray, which is unreadable
                    // against the dark segmented control on this black bar.
                    UISegmentedControl.appearance().setTitleTextAttributes(
                        [.foregroundColor: UIColor.white], for: .normal
                    )
                    UISegmentedControl.appearance().setTitleTextAttributes(
                        [.foregroundColor: UIColor.black], for: .selected
                    )
                }

                if visibleImages.isEmpty {
                    Spacer()
                    Text("画像が見つかりませんでした")
                        .foregroundColor(.gray)
                    Spacer()
                } else if displayMode == .grid {
                    gridContent
                } else {
                    fullscreenContent
                }

                bottomBar
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(pageTitle.isEmpty ? "ImageSaver" : pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(SizeFilter.allCases) { filter in
                            Button {
                                sizeFilter = filter
                            } label: {
                                if filter == sizeFilter {
                                    Label(filter.label, systemImage: "checkmark")
                                } else {
                                    Text(filter.label)
                                }
                            }
                        }

                        Divider()

                        // Always present, even at zero: otherwise a missing
                        // entry is indistinguishable from the scan having
                        // found nothing.
                        if sourceOnlyCount > 0 {
                            Button {
                                includeSourceOnly.toggle()
                            } label: {
                                if includeSourceOnly {
                                    Label("ソース内の画像も表示 (\(sourceOnlyCount)件)",
                                          systemImage: "checkmark")
                                } else {
                                    Text("ソース内の画像も表示 (\(sourceOnlyCount)件)")
                                }
                            }
                        } else {
                            Text("ソース内の画像: なし")
                        }
                    } label: {
                        // Filled while anything is being held back, so hidden
                        // images are discoverable without opening the menu.
                        Image(systemName: hasHiddenImages
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(Array(visibleImages.enumerated()), id: \.element.id) { index, image in
                    ThumbnailCell(
                        image: image,
                        isSelected: selected.contains(image.id),
                        onTapImage: {
                            fullscreenIndex = index
                            displayMode = .fullscreen
                        },
                        onToggleSelect: { toggleSelection(image.id) }
                    )
                    .environmentObject(loader)
                }
            }
        }
        .background(Color.black)
    }

    private var fullscreenContent: some View {
        TabView(selection: $fullscreenIndex) {
            ForEach(Array(visibleImages.enumerated()), id: \.element.id) { index, image in
                FullscreenPreviewView(
                    image: image,
                    isSelected: selected.contains(image.id),
                    onToggleSelect: { toggleSelection(image.id) }
                )
                .environmentObject(loader)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        // A vertical flick (up or down) drops back to the grid. Attached as a
        // simultaneous gesture so the TabView keeps its own horizontal paging.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let vertical = value.translation.height
                    let horizontal = value.translation.width
                    guard abs(vertical) > 70, abs(vertical) > abs(horizontal) * 1.5 else { return }
                    withAnimation { displayMode = .grid }
                }
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            // Always-visible status line: overlays can be suppressed inside an
            // extension's presentation context, so state is mirrored here too.
            HStack(spacing: 6) {
                Text(AppVersion.short)
                    .foregroundColor(.gray)
                Text(statusText)
                    .foregroundColor(statusIsError ? .red : .gray)
                    .lineLimit(1)
                Spacer()

                // Instagram-style carousels keep only the visible slide and its
                // neighbours in the DOM; the rest of the post lives in the page
                // payload. Buried in the filter menu that was undiscoverable,
                // so the count sits here instead.
                if sourceOnlyCount > 0 {
                    Button(includeSourceOnly
                           ? "ソース内を隠す"
                           : "ソース内 +\(sourceOnlyCount)") {
                        includeSourceOnly.toggle()
                    }
                    .font(.system(size: 11))
                }

                // Always available: the previous run's log persists even if the
                // extension was killed before the result could be shown.
                Button("ログ") { showLogSheet = true }
                    .font(.system(size: 11))
            }
            .font(.system(size: 11, design: .monospaced))

            HStack {
                Button(selected.count == visibleImages.count ? "選択解除" : "全て選択") {
                    if selected.count == visibleImages.count {
                        selected.removeAll()
                    } else {
                        selected = Set(visibleImages.map(\.id))
                    }
                }
                .disabled(visibleImages.isEmpty)

                Spacer()

                Button {
                    let targets = images.filter { selected.contains($0.id) }
                    Task {
                        await photoSaver.save(targets)
                        // Saved tiles leave the grid, so drop them from the selection.
                        selected.subtract(photoSaver.savedImageIDs)
                    }
                } label: {
                    Text("保存する (\(selected.count))")
                        .bold()
                }
                .disabled(selected.isEmpty)
            }
        }
        .padding()
        .background(Color.black)
        .overlay(Divider().opacity(0.3), alignment: .top)
    }

    private var hasHiddenImages: Bool {
        sizeFilter != .all
    }

    /// How many images the deeper scan found that the page does not render
    /// itself. Zero means there is nothing to offer and no toggle to show.
    private var sourceOnlyCount: Int {
        images.filter { $0.isFromSourceOnly && !photoSaver.savedImageIDs.contains($0.id) }.count
    }

    private var statusText: String {
        switch photoSaver.state {
        case .idle:
            return "待機中"
        case .saving(let done, let total):
            return "保存中 \(done)/\(total)"
        case .finished(let succeeded, let failed, _):
            return "完了 成功\(succeeded) 失敗\(failed)"
        }
    }

    private var statusIsError: Bool {
        if case .finished(_, let failed, _) = photoSaver.state { return failed > 0 }
        return false
    }

    private func toggleSelection(_ id: Int) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}

private struct ThumbnailCell: View {
    let image: PageImage
    let isSelected: Bool
    let onTapImage: () -> Void
    let onToggleSelect: () -> Void

    @EnvironmentObject private var loader: ImageLoader

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(thumbnail)
            .overlay(badge, alignment: .bottomLeading)
            .overlay(selectionButton, alignment: .topTrailing)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onTapImage() }
            .onAppear { loader.requestThumbnail(for: image) }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.12))

            if let thumbnail = loader.thumbnails[image.id] {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if loader.failed.contains(image.id) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.gray)
            } else {
                ProgressView().tint(.gray)
            }
        }
        .clipped()
    }

    // Bottom-left aligned; the text shrinks rather than spilling past the tile edge.
    private var badge: some View {
        Text(badgeText)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.65))
            .foregroundColor(.white)
            .cornerRadius(3)
            .padding(3)
    }

    private var selectionButton: some View {
        Button(action: onToggleSelect) {
            ZStack {
                // Opaque disc behind the glyph so the state stays legible over
                // bright, busy, or white thumbnails.
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.black.opacity(0.55))
                    .frame(width: 24, height: 24)

                Circle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: 24, height: 24)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(6)
        }
        .buttonStyle(.plain)
    }

    private var badgeText: String {
        // Prefer the real pixel size read from the file; fall back to the DOM's layout size.
        if let size = loader.pixelSizes[image.id] {
            return "\(image.formatLabel) \(Int(size.width))×\(Int(size.height))"
        }
        if image.width > 0, image.height > 0 {
            return "\(image.formatLabel) \(image.width)×\(image.height)"
        }
        return image.formatLabel
    }
}

private struct LogSheet: View {
    let extractionLog: [String]
    let currentLog: [PhotoSaver.LogEntry]
    let previousLog: [String]
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !extractionLog.isEmpty {
                        section(title: "読み込み") {
                            ForEach(Array(extractionLog.enumerated()), id: \.offset) { _, text in
                                line(text, isError: text.hasPrefix("[ERR]"))
                            }
                        }
                    }

                    if !currentLog.isEmpty {
                        section(title: "今回の保存") {
                            ForEach(currentLog) { entry in
                                line(entry.text, isError: entry.isError)
                            }
                        }
                    }

                    if !previousLog.isEmpty {
                        section(title: "前回の記録(強制終了時も残ります)") {
                            ForEach(Array(previousLog.enumerated()), id: \.offset) { _, text in
                                line(text, isError: text.hasPrefix("[ERR]"))
                            }
                        }
                    }

                    if extractionLog.isEmpty && currentLog.isEmpty && previousLog.isEmpty {
                        Text("まだ記録がありません")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("保存ログ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("全部コピー") {
                        UIPasteboard.general.string = allLogText
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { onClose() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var allLogText: String {
        var lines: [String] = []
        if !extractionLog.isEmpty {
            lines.append("=== 読み込み ===")
            lines.append(contentsOf: extractionLog)
        }
        if !currentLog.isEmpty {
            lines.append("=== 今回の保存 ===")
            lines.append(contentsOf: currentLog.map { ($0.isError ? "[ERR] " : "") + $0.text })
        }
        if !previousLog.isEmpty {
            lines.append("=== 前回の記録 ===")
            lines.append(contentsOf: previousLog)
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            content()
        }
    }

    private func line(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(isError ? .red : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
