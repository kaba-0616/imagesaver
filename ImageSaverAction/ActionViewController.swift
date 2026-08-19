import UIKit
import SwiftUI
import MobileCoreServices
import UniformTypeIdentifiers

final class ActionViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let loading = UIHostingController(rootView: LoadingView())
        addChild(loading)
        loading.view.frame = view.bounds
        loading.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(loading.view)
        loading.didMove(toParent: self)

        extractJavaScriptResults { [weak self] images, pageTitle, pageURL, trace in
            guard let self else { return }

            loading.willMove(toParent: nil)
            loading.view.removeFromSuperview()
            loading.removeFromParent()

            let rootView = ImageGridView(
                images: images,
                pageTitle: pageTitle,
                extractionLog: trace,
                onClose: { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
            )

            let hosting = UIHostingController(rootView: rootView)
            self.addChild(hosting)
            hosting.view.frame = self.view.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.view.addSubview(hosting.view)
            hosting.didMove(toParent: self)
        }
    }

    private func extractJavaScriptResults(
        completion: @escaping (
            _ images: [PageImage],
            _ pageTitle: String,
            _ pageURL: String,
            _ trace: [String]
        ) -> Void
    ) {
        // When the page script fails, its own trace is lost with it -- the
        // trace travels inside the very result that went missing. So record
        // what arrived on this side too, or an empty run explains nothing.
        var diagnostics: [String] = []
        let items = extensionContext?.inputItems ?? []
        diagnostics.append("入力アイテム \(items.count)個")

        guard let item = items.first as? NSExtensionItem,
              let attachments = item.attachments else {
            diagnostics.append("[ERR] 共有元からデータを受け取れませんでした")
            DispatchQueue.main.async { completion([], "", "", diagnostics) }
            return
        }

        diagnostics.append("添付 \(attachments.count)個")
        for (index, provider) in attachments.enumerated() {
            diagnostics.append("  添付\(index + 1): "
                               + provider.registeredTypeIdentifiers.joined(separator: ", "))
        }

        let providers = attachments.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }

        guard !providers.isEmpty else {
            diagnostics.append("[ERR] property list 型の添付がありません")
            DispatchQueue.main.async { completion([], "", "", diagnostics) }
            return
        }

        let group = DispatchGroup()
        var resultDict: [String: Any]?

        // loadItem calls back on an arbitrary queue, and there can be more than
        // one provider.
        let lock = NSLock()
        func record(_ line: String) {
            lock.lock()
            diagnostics.append(line)
            lock.unlock()
        }

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, error in
                if let error {
                    record("[ERR] 添付の読み取りに失敗: \(error.localizedDescription)")
                }
                guard let dict = item as? [String: Any] else {
                    // nil here means the page script never completed: an
                    // overrunning script has its result discarded outright.
                    record(item == nil
                           ? "[ERR] 添付が nil (ページ側スクリプトが完了せず破棄された)"
                           : "[ERR] 想定外の型: \(String(describing: item))")
                    group.leave()
                    return
                }
                record("辞書キー: \(dict.keys.sorted().joined(separator: ", "))")

                if let js = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                    lock.lock()
                    resultDict = js
                    lock.unlock()
                } else {
                    // The key is absent when the page script never called its
                    // completion function -- it threw, or it ran too long.
                    record("[ERR] JS実行結果のキーがありません"
                           + "(スクリプトが完了しなかった可能性)")
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let pageTitle = resultDict?["pageTitle"] as? String ?? ""
            let pageURL = resultDict?["pageURL"] as? String ?? ""
            let rawImages = resultDict?["images"] as? [[String: Any]] ?? []
            var trace = diagnostics
            trace.append(contentsOf: resultDict?["trace"] as? [String] ?? [])
            if resultDict == nil {
                trace.append("[ERR] 抽出スクリプトの結果が空でした")
            }

            var images: [PageImage] = []
            images.reserveCapacity(rawImages.count)
            for (index, raw) in rawImages.enumerated() {
                guard let urlString = raw["url"] as? String, let url = URL(string: urlString) else { continue }
                let width = (raw["width"] as? NSNumber)?.intValue ?? 0
                let height = (raw["height"] as? NSNumber)?.intValue ?? 0
                let origin = raw["origin"] as? String ?? "dom"
                images.append(PageImage(
                    id: index,
                    url: url,
                    width: width,
                    height: height,
                    isFromSourceOnly: origin == "source"
                ))
            }

            let sourceOnly = images.filter(\.isFromSourceOnly).count
            trace.append("受け取り \(images.count)件 "
                         + "(ページ内 \(images.count - sourceOnly) / ソース内 \(sourceOnly))")

            completion(images, pageTitle, pageURL, trace)
        }
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("ページを解析中…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
