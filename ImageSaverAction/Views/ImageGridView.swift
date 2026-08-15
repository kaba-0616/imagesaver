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

    @StateObject private var loader = ImageLoader.shared
    @StateObject private var photoSaver = PhotoSaver()

    @State private var selected: Set<Int> = []
    @State private var displayMode: DisplayMode = .grid
    @State private var sizeFilter: SizeFilter = .all
    @State private var fullscreenIndex: Int = 0

    private var visibleImages: [PageImage] {
        guard sizeFilter != .all else { return images }
        let threshold = sizeFilter.rawValue
        return images.filter { image in
            let known = max(image.width, image.height)
            return known == 0 || known >= threshold
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 4)]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("表示", selection: $displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if visibleImages.isEmpty {
                    Spacer()
                    Text("画像が見つかりませんでした")
                        .foregroundColor(.secondary)
                    Spacer()
                } else if displayMode == .grid {
                    gridContent
                } else {
                    fullscreenContent
                }

                bottomBar
            }
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
        .overlay(savingOverlay)
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
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
            .padding(4)
        }
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
                Task { await photoSaver.save(targets) }
            } label: {
                Text("保存する (\(selected.count))")
                    .bold()
            }
            .disabled(selected.isEmpty)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var savingOverlay: some View {
        switch photoSaver.state {
        case .idle:
            EmptyView()
        case .saving(let done, let total):
            ProgressOverlay(text: "保存中… \(done)/\(total)")
        case .finished(let succeeded, let failed):
            ResultOverlay(succeeded: succeeded, failed: failed) {
                photoSaver.reset()
                selected.removeAll()
            }
        }
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
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = loader.thumbnails[image.id] {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if loader.failed.contains(image.id) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 110, height: 110)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onTapImage() }
            .onAppear { loader.requestThumbnail(for: image) }

            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .white)
                    .background(Circle().fill(Color.black.opacity(0.3)))
                    .padding(4)
            }

            VStack {
                Spacer()
                HStack {
                    Text(image.formatLabel)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(Color.black.opacity(0.5))
                        .foregroundColor(.white)
                        .cornerRadius(3)
                    Spacer()
                }
            }
            .frame(width: 110, height: 110)
        }
        .cornerRadius(6)
    }
}

private struct ProgressOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(text).foregroundColor(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
        }
    }
}

private struct ResultOverlay: View {
    let succeeded: Int
    let failed: Int
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 40))
                    .foregroundColor(failed == 0 ? .green : .orange)
                Text(failed == 0
                     ? "\(succeeded)枚を保存しました"
                     : "\(succeeded)枚保存、\(failed)枚失敗しました")
                Button("OK") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.regularMaterial)
            .cornerRadius(12)
        }
    }
}
