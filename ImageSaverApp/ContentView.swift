import SwiftUI

struct ContentView: View {
    @State private var history: [HistoryEntry] = HistoryStore.load()

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("使い方")
                            .font(.headline)
                        Text("1. Safariで画像を保存したいページを開く")
                        Text("2. 共有ボタンをタップし「ImageSaver」を選択")
                        Text("3. 一覧から画像を選んで保存")
                    }
                    .font(.subheadline)
                    .padding(.vertical, 4)

                    NavigationLink(destination: EnableExtensionGuideView()) {
                        Label("機能拡張が表示されない場合", systemImage: "questionmark.circle")
                    }
                }

                if !history.isEmpty {
                    Section("最近開いたページ") {
                        ForEach(history) { entry in
                            Button {
                                openInSafari(entry.pageURL)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.pageTitle.isEmpty ? entry.pageURL : entry.pageTitle)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text("\(entry.imageCount)枚の画像 ・ \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("ImageSaver")
            .onAppear { history = HistoryStore.load() }
        }
    }

    private func openInSafari(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct EnableExtensionGuideView: View {
    var body: some View {
        List {
            Text("ImageSaverはSafariの共有シートの「アクション」として動作します。共有ボタンをタップし、アイコンが並んだ列を左端までスワイプして「その他」をタップ、「アクションを編集」でImageSaverをオンにしてください。設定アプリではなく、Safariの共有シートの中に設定箇所があります。")
        }
        .navigationTitle("機能拡張の有効化")
    }
}

#Preview {
    ContentView()
}
