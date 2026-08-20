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

        extractJavaScriptResults { [weak self] images, pageTitle, pageURL in
            guard let self else { return }

            HistoryStore.recordVisit(pageURL: pageURL, pageTitle: pageTitle, imageCount: images.count)

            loading.willMove(toParent: nil)
            loading.view.removeFromSuperview()
            loading.removeFromParent()

            let rootView = ImageGridView(
                images: images,
                pageTitle: pageTitle,
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
        completion: @escaping (_ images: [PageImage], _ pageTitle: String, _ pageURL: String) -> Void
    ) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            DispatchQueue.main.async { completion([], "", "") }
            return
        }

        let providers = attachments.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }

        guard !providers.isEmpty else {
            DispatchQueue.main.async { completion([], "", "") }
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

            completion(images, pageTitle, pageURL)
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
