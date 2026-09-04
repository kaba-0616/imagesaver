import SwiftUI
import Photos

struct ContentView: View {
    // .readWrite, not .addOnly: the duplicate finder below needs full access
    // regardless, and asking for .addOnly here first used to mean two
    // separate permission prompts (add-only now, then a second upgrade to
    // full access the first time "写真の重複を整理" is opened) -- each an
    // extra round trip that a sideloaded free-signed build's every reinstall
    // makes the user sit through again. One prompt, covering both, is what
    // this screen asks for now.
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

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

                // Saving the same picture twice is what this app does when you
                // share a page you have shared before, so the duplicates it
                // creates are its own to clean up.
                Section {
                    NavigationLink(destination: LazyView(DuplicateFinderView())) {
                        Label("写真の重複を整理", systemImage: "square.on.square.dashed")
                    }
                } footer: {
                    Text("同じ写真と似ている写真をまとめて表示します。削除するものは自分で選びます。")
                }

                // A photo edited this way keeps its place in the library --
                // this crops in place as a Photos edit, not a delete-and-
                // replace, so "編集を戻す" in the system Photos app is the
                // undo story rather than anything this app has to build.
                Section {
                    NavigationLink(destination: LazyView(MarginCropFinderView())) {
                        Label("写真の余白を整理", systemImage: "crop")
                    }
                } footer: {
                    Text("上下・左右・四辺に単色の余白がある写真をまとめて見つけて、トリミングします。")
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
            }
            .navigationTitle("ImageSaver")
            .onAppear {
                photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
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

/// `NavigationLink(destination:)` built from a plain view value gets that
/// view constructed as soon as the row appears in the list -- before it is
/// ever tapped -- because `NavigationView`/`List` evaluate the destination to
/// size and diff it. For `DuplicateFinderView` that construction runs
/// `DuplicateScanner.init()`, which starts a full scan of the whole photo
/// library. The real tap then builds a second, separate instance and starts
/// a second scan on top of the first -- this defers construction until the
/// destination is actually pushed, so only the real navigation creates it.
private struct LazyView<Content: View>: View {
    private let build: () -> Content
    init(_ build: @autoclosure @escaping () -> Content) { self.build = build }
    var body: Content { build() }
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
