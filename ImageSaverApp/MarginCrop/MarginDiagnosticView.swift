import Photos
import PhotosUI
import SwiftUI
import UIKit

/// A debug screen: pick one photo from the library and see the raw numbers
/// `MarginDetector` computed for each of its four edges, at every detection
/// level -- rather than guessing which threshold is wrong from a screenshot
/// of a photo that got missed. Reachable only from the settings sheet; not
/// part of the normal scan/trim flow.
struct MarginDiagnosticView: View {

    /// When set, this screen loads straight from that asset instead of
    /// opening the picker -- lets the fullscreen preview jump a candidate
    /// it is already showing directly into diagnosis, rather than making
    /// the user re-find the same photo through the picker.
    var presetLocalIdentifier: String?

    @State private var showingPicker = false
    @State private var rows: [MarginDetector.EdgeDiagnosticRow]?
    @State private var pickedSize: String?
    @State private var errorText: String?
    @State private var level = Double(MarginLevel.stored())

    var body: some View {
        List {
            Section {
                Button("写真を選ぶ") { showingPicker = true }
                if let pickedSize {
                    Text("選択中: \(pickedSize)")
                        .foregroundColor(.secondary)
                }
                Button("全レベルをコピー") { copyAllLevelsToClipboard() }
                    .disabled(lastImage == nil)
            }
            Section {
                Stepper("判定レベル: \(Int(level))", value: $level, in: 0...10, step: 1)
                    .onChange(of: level) { _ in rerun() }
            }
            if let errorText {
                Section {
                    Text(errorText).foregroundColor(.red)
                }
            }
            if let rows {
                ForEach(rows) { row in
                    Section(row.edge) {
                        diagnosticRow(row.diagnostics)
                    }
                }
            }
        }
        .navigationTitle("余白診断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("コピー") { copyToClipboard() }
                    .disabled(rows == nil)
            }
        }
        .sheet(isPresented: $showingPicker) {
            MarginDiagnosticPicker { image, size in
                pickedSize = size
                lastImage = image
                rerun()
            }
        }
        .task {
            guard lastImage == nil, let presetLocalIdentifier else { return }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [presetLocalIdentifier], options: nil).firstObject else {
                errorText = "写真が見つかりませんでした"
                return
            }
            guard let (image, size) = await Self.downsample(asset: asset) else {
                errorText = "画像の読み込みに失敗しました"
                return
            }
            pickedSize = size
            lastImage = image
            rerun()
        }
    }

    /// Fetches and downsamples a `PHAsset` through the exact same API
    /// (`PHImageManager.requestImage`, 512x512 aspect fit) `MarginCropScanner
    /// .performScan` uses for the real scan -- so a number this screen shows
    /// is guaranteed to be what a real scan actually computed, not a
    /// approximation from a differently-built downsample. `MarginDiagnosticPicker`
    /// used to build its own with `UIGraphicsImageRenderer`, which turned out
    /// not to match: the two produced different pixel dimensions for the
    /// "same" 512x512 target, so numbers taken through the picker and through
    /// this asset-based path disagreed on real photos even before any
    /// detection-logic change.
    static func downsample(asset: PHAsset) async -> (CGImage, String)? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            let target = CGSize(width: 512, height: 512)
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                                  options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, let image, let cgImage = image.cgImage else {
                    if degraded { return }
                    continuation.resume(returning: nil)
                    return
                }
                let label = "\(asset.pixelWidth)x\(asset.pixelHeight)"
                continuation.resume(returning: (cgImage, label))
            }
        }
    }

    @State private var lastImage: CGImage?

    // The on-screen rows are fine for a quick look, but every real
    // diagnosis so far has meant retyping numbers off a photo of the screen
    // into a chat -- copying the same text this view renders sidesteps that
    // entirely.
    private func copyToClipboard() {
        guard let rows, let pickedSize else { return }
        var lines = ["余白診断: \(pickedSize) レベル\(Int(level))"]
        for row in rows {
            let d = row.diagnostics
            lines.append("[\(row.edge)] 一致率=\(String(format: "%.2f", d.matchFraction))"
                + "(必要\(String(format: "%.2f", MarginLevel.minMatchFraction(for: Int(level))))) "
                + "彩度=\(String(format: "%.1f", d.saturation))(上限\(MarginLevel.saturationLimit)) "
                + "輝度=\(String(format: "%.1f", d.luminance)) 最浅深さ=\(d.shallowest)px "
                + "列一致率=\(String(format: "%.2f", d.inlierFraction))(必要0.70) "
                + (d.rejectedAt.map { "棄却: \($0)" } ?? "採用: \(d.depth)px"))
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
    }

    // "数値だけ見ても実際どのレベルまで検出範囲になるか分からない" という
    // フィードバックへの対応 -- スライダーで1レベルずつ動かして都度コピーする
    // 代わりに、レベル0〜10のすべてで採用/棄却と深さを一括計算し、1回のコピーで
    // 「このレベルからこの深さで切れ始める」という境目がそのまま読み取れるように
    // する。表示中の単一レベルの行(`rows`)やスライダー位置には触れない。
    private func copyAllLevelsToClipboard() {
        guard let lastImage, let pickedSize else { return }
        var lines = ["余白診断(全レベル): \(pickedSize)"]
        for lv in 0...10 {
            guard let levelRows = MarginDetector.diagnose(in: lastImage, level: lv) else {
                lines.append("レベル\(lv): 解析失敗")
                continue
            }
            let parts = levelRows.map { row -> String in
                let d = row.diagnostics
                return "\(row.edge)=" + (d.rejectedAt.map { "棄却(\($0))" } ?? "\(d.depth)px")
            }.joined(separator: " ")
            lines.append("レベル\(lv): \(parts)")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
    }

    private func rerun() {
        guard let lastImage else { return }
        // Deliberately does not call `MarginLevel.store` -- this screen's
        // level slider is scoped to this diagnosis only and must not change
        // the real scan's persisted sensitivity as a side effect of poking
        // around here.
        rows = MarginDetector.diagnose(in: lastImage, level: Int(level))
        errorText = rows == nil ? "画像の解析に失敗しました" : nil
    }

    // Plain HStack rows, not `LabeledContent` -- that API needs iOS 16, and
    // this project's deployment target is still 15.0 (this screen is not an
    // exception to that).
    @ViewBuilder
    private func diagnosticRow(_ d: MarginDetector.EdgeDiagnostics) -> some View {
        labeledRow("一致率", String(format: "%.2f (必要 %.2f)", d.matchFraction, MarginLevel.minMatchFraction(for: Int(level))))
        labeledRow("彩度", String(format: "%.1f (上限 %d)", d.saturation, MarginLevel.saturationLimit))
        labeledRow("輝度", String(format: "%.1f", d.luminance))
        labeledRow("最浅の深さ", "\(d.shallowest)px")
        labeledRow("列の一致率", String(format: "%.2f (必要 0.70)", d.inlierFraction))
        HStack {
            Text("結果")
            Spacer()
            if let rejectedAt = d.rejectedAt {
                Text("棄却: \(rejectedAt)").foregroundColor(.red)
            } else {
                Text("採用: \(d.depth)px").foregroundColor(.green)
            }
        }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

/// `PHPickerViewController` wrapper -- limited to one image. Resolves the
/// pick back to a `PHAsset` and reuses `MarginDiagnosticView.downsample(asset:)`
/// so this and the fullscreen-preview diagnostic path always agree; see that
/// function's comment for why a separate, self-built downsample here used to
/// disagree with the real scan.
private struct MarginDiagnosticPicker: UIViewControllerRepresentable {
    let onPicked: (CGImage, String) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (CGImage, String) -> Void
        init(onPicked: @escaping (CGImage, String) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }
            // `assetIdentifier` (present whenever the picker is backed by
            // `.shared()`, as it is here) lets this go through the same
            // `PHImageManager`-based downsample the real scan and the
            // fullscreen-preview diagnostic path both use -- see
            // `MarginDiagnosticView.downsample(asset:)`. Falling back to the
            // item provider's own `UIImage` only covers a picker configured
            // without library access, which is not this one, but costs
            // nothing to keep as a safety net.
            if let identifier = result.assetIdentifier,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
                Task {
                    guard let (cgImage, label) = await MarginDiagnosticView.downsample(asset: asset) else { return }
                    await MainActor.run { self.onPicked(cgImage, label) }
                }
                return
            }
            guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else { return }
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let uiImage = object as? UIImage else { return }
                let target = CGSize(width: 512, height: 512)
                let scale = min(target.width / uiImage.size.width, target.height / uiImage.size.height, 1)
                let size = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: size)
                let resized = renderer.image { _ in uiImage.draw(in: CGRect(origin: .zero, size: size)) }
                guard let cgImage = resized.cgImage else { return }
                let label = "\(Int(uiImage.size.width))x\(Int(uiImage.size.height))"
                DispatchQueue.main.async {
                    self.onPicked(cgImage, label)
                }
            }
        }
    }
}
