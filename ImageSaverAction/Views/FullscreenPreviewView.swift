import SwiftUI

struct FullscreenPreviewView: View {
    let image: PageImage
    let isSelected: Bool
    let onToggleSelect: () -> Void

    @EnvironmentObject private var loader: ImageLoader
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Fills the whole page slot so `content` centers within it
            // instead of collapsing to the top.
            Color.black
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .onAppear { loader.requestFullImage(for: image) }

            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 28))
                    .foregroundColor(isSelected ? .accentColor : .white)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .padding()
            }

            VStack {
                Spacer()
                Text(infoText)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .padding(.bottom, 44)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var infoText: String {
        if let size = loader.pixelSizes[image.id] {
            return "\(image.formatLabel)  \(Int(size.width))×\(Int(size.height))"
        }
        if image.width > 0, image.height > 0 {
            return "\(image.formatLabel)  \(image.width)×\(image.height)"
        }
        return image.formatLabel
    }

    @ViewBuilder
    private var content: some View {
        if let full = loader.fullImages[image.id] {
            Image(uiImage: full)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let thumbnail = loader.thumbnails[image.id] {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay(ProgressView())
        } else if loader.failed.contains(image.id) {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text("読み込みに失敗しました")
            }
            .foregroundColor(.white)
        } else {
            ProgressView().tint(.white)
        }
    }
}
