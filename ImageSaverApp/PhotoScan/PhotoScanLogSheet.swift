import SwiftUI
import UIKit

/// The scan's log, in a form it can be got back out of.
///
/// Reading it on screen is not the point. Development happens on a machine that
/// cannot run this app at all, so the only route a measurement from a real
/// device ever takes is the user copying this text and pasting it back. A log
/// that can be looked at but not extracted would, here, be the same as no log.
///
/// Named for the app on purpose: the extension has a `LogSheet` of its own, and
/// although the two targets are compiled separately, one of them being opened
/// by mistake while chasing a bug would cost a day.
struct PhotoScanLogSheet: View {

    @ObservedObject var log: PhotoScanLog
    let onClose: () -> Void

    @State private var sharing = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if log.newestFirst.isEmpty {
                        Text("まだ記録がありません")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(log.newestFirst) { run in
                            section(run)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("写真整理のログ")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $sharing) {
                PhotoScanActivityView(text: allText)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // A plain "copy all" button used to hand Claude every run
                    // kept on the device at once -- fine for the person
                    // pasting it, expensive for the tokens on the other end.
                    // Most questions are about the run that just finished.
                    Menu("コピー") {
                        ForEach([1, 3, 5], id: \.self) { count in
                            Button("直近\(count)件") { copy(recentRuns: count) }
                        }
                        Button("全部(\(log.newestFirst.count)件)") { copy(recentRuns: log.newestFirst.count) }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        sharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { onClose() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            line(AppVersion.short, error: false)
            line(memoryLine, error: false)
        }
    }

    /// Read as the sheet is drawn, so it reports the moment the log was opened
    /// rather than whatever it was when the screen was entered.
    private var memoryLine: String {
        "メモリ \(Footprint.megabytes)MB / 記録された実行 \(log.newestFirst.count)件"
    }

    private var allText: String {
        AppVersion.short + "\n" + memoryLine + "\n\n" + log.allText
    }

    private func copy(recentRuns: Int) {
        UIPasteboard.general.string = AppVersion.short + "\n" + memoryLine + "\n\n" + log.text(recentRuns: recentRuns)
    }

    private func section(_ run: PhotoScanRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            if run.lines.isEmpty {
                line("(記録なし)", error: false)
            } else {
                ForEach(Array(run.lines.enumerated()), id: \.offset) { _, entry in
                    line("\(PhotoScanFormat.stamp(entry.at))  \(entry.text)",
                         error: entry.text.hasPrefix("[!]"))
                }
            }
        }
    }

    private func line(_ text: String, error: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(error ? .red : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// Hands the log to the system share sheet. ShareLink would be one line, but it
/// needs iOS 16 and this app still supports 15.
private struct PhotoScanActivityView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
