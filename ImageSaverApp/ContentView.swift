import SwiftUI

struct ContentView: View {
    @ObservedObject private var subscriptions = SubscriptionManager.shared

    var body: some View {
        NavigationView {
            List {
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

                // A candidate finder, not an editor -- see
                // `MarginCropScanner`'s own header comment for why this
                // stopped short of cropping the photo itself.
                Section {
                    NavigationLink(destination: LazyView(MarginCropFinderView())) {
                        Label("写真の余白を整理", systemImage: "crop")
                    }
                } footer: {
                    Text("上下・左右・四辺に単色の余白がある写真をまとめて見つけます。手動でトリミングしたい写真を探す一覧としてご利用ください。")
                }

                // Usage instructions, Photos permission, version, and
                // purchase status all live in here now -- this screen's job
                // is just the two tools plus a way to reach the rest.
                Section {
                    NavigationLink(destination: SettingsView()) {
                        Label("設定", systemImage: "gearshape")
                    }
                }

                // Bottom of the list, not top: this screen's job is the two
                // tools, not the ad. Hidden entirely (not just skipped) once
                // either plan is active -- AdBannerView would otherwise
                // still spend a request/fill on an ad nobody paid to avoid
                // seeing.
                if !subscriptions.isAdsRemoved {
                    Section {
                        AdBannerView(.top)
                            .frame(height: 50)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .navigationTitle("ImageSaver")
            .onAppear {
                AdsManager.shared.start()
            }
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

#Preview {
    ContentView()
}
