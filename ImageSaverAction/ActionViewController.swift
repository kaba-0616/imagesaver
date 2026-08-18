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

            HistoryStore.recordVisit(pageURL: pageURL, pageTitle: pageTitle, imageCount: images.count)

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
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            DispatchQueue.main.async {
                completion([], "", "", ["[ERR] 共有元からデータを受け取れませんでした"])
            }
            return
        }

        let providers = attachments.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }

        guard !providers.isEmpty else {
            DispatchQueue.main.async {
                completion([], "", "", ["[ERR] ページの解析結果が添付されていません"])
            }
            return
        }

        let group = DispatchGroup()
        var resultDict: [String: Any]?

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, _ in
                if let dict = item as? [String: Any],
                   let js = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                    resultDict = js
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let pageTitle = resultDict?["pageTitle"] as? String ?? ""
            let pageURL = resultDict?["pageURL"] as? String ?? ""
            let rawImages = resultDict?["images"] as? [[String: Any]] ?? []
            var trace = resultDict?["trace"] as? [String] ?? []
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
