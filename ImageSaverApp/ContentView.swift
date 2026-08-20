import SwiftUI
import Photos

struct ContentView: View {
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

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

                // The extension cannot safely raise the Photos permission prompt
                // itself, so it has to be granted here first.
                Section {
                    HStack {
                        Label("写真への保存", systemImage: statusIcon)
                            .foregroundColor(statusColor)
                        Spacer()
                        Text(statusText)
                            .foregroundColor(.secondary)
                    }

                    if photoStatus == .notDetermined {
                        Button("写真への保存を許可する") {
                            Task {
                                photoStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
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
                    Text("共有シートから保存する前に、ここで写真への保存を許可しておく必要があります。")
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
            }
            .navigationTitle("ImageSaver")
            .onAppear {
                photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            }
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
    ContentView()
}
