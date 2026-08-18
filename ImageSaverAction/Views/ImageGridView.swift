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

    var label: String {
        switch self {
        case .all: return "すべて表示"
        case .medium: return "100px未満を除外"
        case .large: return "300px未満を除外"
        }
    }
}

struct ImageGridView: View {
    let images: [PageImage]
    let pageTitle: String
    let onClose: () -> Void

    @StateObject private var loader = ImageLoader()
    @StateObject private var photoSaver = PhotoSaver()

    @State private var selected: Set<Int> = []
    @State private var displayMode: DisplayMode = .grid
    @State private var sizeFilter: SizeFilter = .all
    @State private var fullscreenIndex: Int = 0
    @State private var showLogSheet = false

    private var visibleImages: [PageImage] {
        images.filter { image in
            // Already-saved images drop out of the grid so it's obvious what is left to do.
            guard !photoSaver.savedImageIDs.contains(image.id) else { return false }
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
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showLogSheet) {
                LogSheet(
                    currentLog: photoSaver.log,
                    previousLog: PersistentLog.read()
                ) { showLogSheet = false }
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
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
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
    let currentLog: [PhotoSaver.LogEntry]
    let previousLog: [String]
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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

                    if currentLog.isEmpty && previousLog.isEmpty {
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
