import SwiftUI

/// Shown when the page-extraction script returned nothing at all.
///
/// Safari can freeze a page's timers once the share sheet covers it, and the
/// script that walks Instagram's carousel needs them. When that happens there
/// is nothing to recover -- but re-sharing almost always succeeds, so say so
/// rather than presenting an empty grid that looks like a page with no images.
struct ExtractionFailedView: View {
    let onShowLog: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 52))
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("ページの解析に失敗しました")
                    .font(.headline)

                Text("この画面を閉じて、もう一度共有し直してください。\n続けて失敗する場合は、ページを再読み込みしてからお試しください。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button("閉じる", action: onClose)
                    .font(.body.bold())

                Button("ログを見る", action: onShowLog)
                    .font(.footnote)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundColor(.white)
        .preferredColorScheme(.dark)
    }
}

/// Wraps the failure screen so its log sheet has somewhere to live.
struct ExtractionFailedRootView: View {
    let extractionLog: [String]
    let onClose: () -> Void

    @State private var showLog = false

    var body: some View {
        ExtractionFailedView(
            onShowLog: { showLog = true },
            onClose: onClose
        )
        .sheet(isPresented: $showLog) {
            LogSheet(
                extractionLog: extractionLog,
                currentLog: [],
                previousLog: PersistentLog.read()
            ) { showLog = false }
        }
    }
}
