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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 3)

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
        .overlay(savingOverlay)
        .preferredColorScheme(.dark)
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
        .background(Color.black)
        .overlay(Divider().opacity(0.3), alignment: .top)
    }

    @ViewBuilder
    private var savingOverlay: some View {
        switch photoSaver.state {
        case .idle:
            EmptyView()
        case .saving(let done, let total):
            ProgressOverlay(text: "保存中… \(done)/\(total)")
        case .finished(let succeeded, let failed, let message):
            ResultOverlay(succeeded: succeeded, failed: failed, message: message) {
                photoSaver.reset()
                if failed == 0 { selected.removeAll() }
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
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(Color(white: 0.12))

                    Group {
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

                    // Format + pixel dimensions. Constrained to the cell width and
                    // allowed to shrink so long labels never overflow the tile.
                    VStack {
                        Spacer()
                        HStack(spacing: 0) {
                            Text(badgeText)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.black.opacity(0.6))
                                .foregroundColor(.white)
                                .cornerRadius(3)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(3)

                    Button(action: onToggleSelect) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .symbolRenderingModeIfAvailable()
                            .foregroundColor(isSelected ? .accentColor : Color.white.opacity(0.85))
                            .shadow(radius: 2)
                            .padding(5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            )
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onTapImage() }
            .onAppear { loader.requestThumbnail(for: image) }
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

private extension View {
    // Keeps the checkmark readable over both light and dark thumbnails.
    func symbolRenderingModeIfAvailable() -> some View {
        if #available(iOS 15.0, *) {
            return AnyView(self.symbolRenderingMode(.hierarchical))
        }
        return AnyView(self)
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
    let message: String?
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 40))
                    .foregroundColor(failed == 0 ? .green : .orange)

                Text(failed == 0
                     ? "\(succeeded)枚を保存しました"
                     : "\(succeeded)枚保存、\(failed)枚失敗しました")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if failed == 0 {
                    Text("「写真」アプリの最近の項目に追加されています")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("OK") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial)
            .cornerRadius(12)
            .padding(24)
        }
    }
}
