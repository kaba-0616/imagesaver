import SwiftUI
import Photos

/// Everything that used to live directly on the TOP screen but isn't one of
/// its two tools -- usage instructions, the Photos permission row, version,
/// and purchase status -- moved here so the TOP list stays just "the two
/// tools" plus a way in here.
struct SettingsView: View {
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @State private var restoreMessage: String?

    var body: some View {
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

            // The extension cannot safely raise the Photos permission prompt
            // itself, so it has to be granted here first.
            Section {
                HStack {
                    Label("写真へのアクセス", systemImage: statusIcon)
                        .foregroundColor(statusColor)
                    Spacer()
                    Text(statusText)
                        .foregroundColor(.secondary)
                }

                if photoStatus == .notDetermined {
                    Button("写真へのアクセスを許可する") {
                        Task {
                            photoStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                        }
                    }
                } else if photoStatus == .denied || photoStatus == .restricted {
                    Button("設定アプリを開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("必要な許可")
            } footer: {
                Text("共有シートから保存する前と、「写真の重複を整理」を使う前、両方でここでの許可が必要です。1回の許可でどちらにも使えます。")
            }

            Section("バージョン") {
                HStack {
                    Text("インストール中のビルド")
                    Spacer()
                    Text(AppVersion.short)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // App Review requires a way to restore a subscription without
            // repurchasing (Guideline 3.1.1).
            Section {
                HStack {
                    Text("購入状況")
                    Spacer()
                    Text(subscriptionStatusText)
                        .foregroundColor(.secondary)
                }
                NavigationLink("プランを見る") {
                    PaywallView()
                }
                Button("購入を復元") {
                    Task {
                        do {
                            try await subscriptions.restorePurchases()
                            restoreMessage = subscriptions.isSubscribed
                                ? "復元しました" : "復元できる購入が見つかりませんでした"
                        } catch {
                            restoreMessage = "復元に失敗しました: \(error.localizedDescription)"
                        }
                    }
                }
                if let restoreMessage {
                    Text(restoreMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("Lite: 広告非表示 / Full: 広告非表示+削除回数無制限。購入画面は準備中です。")
            }

            // Its own placement (separate from TOP's) so AdMob's reporting
            // can tell the two apart, same reasoning as the three tool
            // screens' banners.
            if !subscriptions.isAdsRemoved {
                Section {
                    AdBannerView(.settings)
                        .frame(height: 50)
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            Task {
                await subscriptions.loadProducts()
            }
        }
    }

    private var subscriptionStatusText: String {
        switch subscriptions.tier {
        case .full: return "Full 有効"
        case .lite: return "Lite 有効"
        case nil: return "未購入"
        }
    }

    private var statusText: String {
        switch photoStatus {
        case .authorized: return "許可済み"
        case .limited: return "一部のみ許可"
        case .denied: return "拒否"
        case .restricted: return "制限あり"
        case .notDetermined: return "未設定"
        @unknown default: return "不明"
        }
    }

    private var statusIcon: String {
        switch photoStatus {
        case .authorized, .limited: return "checkmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch photoStatus {
        case .authorized, .limited: return .green
        default: return .orange
        }
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
    NavigationView { SettingsView() }
}
