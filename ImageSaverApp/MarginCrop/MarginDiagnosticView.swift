import Photos
import PhotosUI
import SwiftUI

/// A debug screen: pick one photo from the library and see the raw numbers
/// `MarginDetector` computed for each of its four edges, at every detection
/// level -- rather than guessing which threshold is wrong from a screenshot
/// of a photo that got missed. Reachable only from the settings sheet; not
/// part of the normal scan/trim flow.
struct MarginDiagnosticView: View {

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
        .sheet(isPresented: $showingPicker) {
            MarginDiagnosticPicker { image, size in
                pickedSize = size
                lastImage = image
                rerun()
            }
        }
    }

    @State private var lastImage: CGImage?

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

/// `PHPickerViewController` wrapper -- limited to one image, and reads back
/// the same 512x512 aspect-fit `CGImage` the real scan feeds into
/// `MarginDetector.detect`, so the diagnostic numbers match what a real scan
/// would have seen for this photo.
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
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let uiImage = object as? UIImage else { return }
                // Match the real scan's downsample exactly (512x512, aspect
                // fit) so the numbers shown here are what a real scan would
                // have computed for this photo, not a higher- or
                // lower-resolution stand-in.
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
