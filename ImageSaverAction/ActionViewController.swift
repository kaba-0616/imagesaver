import UIKit
import SwiftUI
import MobileCoreServices
import UniformTypeIdentifiers

final class ActionViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        RunID.beginRun()

        let loading = UIHostingController(rootView: LoadingView())
        addChild(loading)
        loading.view.frame = view.bounds
        loading.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(loading.view)
        loading.didMove(toParent: self)

        extractJavaScriptResults { [weak self] result in
            guard let self else { return }

            loading.willMove(toParent: nil)
            loading.view.removeFromSuperview()
            loading.removeFromParent()

            let close: () -> Void = { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }

            let hosting: UIHostingController<AnyView>
            if result.scriptFailed {
                hosting = UIHostingController(rootView: AnyView(
                    ExtractionFailedRootView(extractionLog: result.trace, onClose: close)
                ))
            } else {
                hosting = UIHostingController(rootView: AnyView(
                    ImageGridView(
                        images: result.images,
                        pageTitle: result.pageTitle,
                        extractionLog: result.trace,
                        onClose: close
                    )
                ))
            }
            self.addChild(hosting)
            hosting.view.frame = self.view.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.view.addSubview(hosting.view)
            hosting.didMove(toParent: self)
        }
    }

    struct ExtractionResult {
        let images: [PageImage]
        let pageTitle: String
        let trace: [String]
        /// The page script returned nothing at all, which is recoverable by
        /// re-sharing -- distinct from a page that genuinely has no images.
        let scriptFailed: Bool
    }

    private func extractJavaScriptResults(
        completion: @escaping (ExtractionResult) -> Void
    ) {
        // When the page script fails, its own trace is lost with it -- the
        // trace travels inside the very result that went missing. So record
        // what arrived on this side too, or an empty run explains nothing.
        var diagnostics: [String] = []
        let items = extensionContext?.inputItems ?? []
        diagnostics.append("入力アイテム \(items.count)個")

        func fail(_ reason: String) {
            diagnostics.append(reason)
            let trace = diagnostics
            DispatchQueue.main.async {
                completion(ExtractionResult(images: [], pageTitle: "",
                                            trace: trace, scriptFailed: true))
            }
        }

        guard let item = items.first as? NSExtensionItem,
              let attachments = item.attachments else {
            fail("[ERR] 共有元からデータを受け取れませんでした")
            return
        }

        diagnostics.append("添付 \(attachments.count)個")

        let providers = attachments.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }

        guard !providers.isEmpty else {
            fail("[ERR] property list 型の添付がありません")
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
                    // Safari delivers "no result" as nil or as an archived null.
                    record("[ERR] 解析結果が空 (ページ側スクリプトが完了しなかった)")
                    group.leave()
                    return
                }

                if let js = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                    lock.lock()
                    resultDict = js
                    lock.unlock()
                } else {
                    record("[ERR] JS実行結果のキーがありません")
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let pageTitle = resultDict?["pageTitle"] as? String ?? ""
            let rawImages = resultDict?["images"] as? [[String: Any]] ?? []
            var trace = diagnostics
            trace.append(contentsOf: resultDict?["trace"] as? [String] ?? [])

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

            completion(ExtractionResult(
                images: images,
                pageTitle: pageTitle,
                trace: trace,
                scriptFailed: resultDict == nil
            ))
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
