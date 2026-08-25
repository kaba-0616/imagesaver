import Combine
import Foundation

struct PhotoScanLogLine: Codable, Equatable {
    let at: Date
    let text: String
}

struct PhotoScanRun: Codable, Equatable, Identifiable {
    let number: Int
    let startedAt: Date
    let build: String
    var lines: [PhotoScanLogLine]

    var id: Int { number }

    var label: String {
        "実行 #\(number)  \(PhotoScanFormat.stamp(startedAt))  \(build)"
    }
}

/// The scan's own account of itself, kept across runs.
///
/// The extension's RunID/PersistentLog are not reused here on purpose: those
/// keep exactly one run in UserDefaults because an extension is killed without
/// warning and has almost no memory to spare. This screen has neither problem
/// and needs the opposite -- several runs kept side by side, so a scan that
/// went wrong can be compared with the one before it.
///
/// Nothing here is decoration. How long a library of this size takes to scan,
/// how many photos never produced a fingerprint, and which threshold produced
/// which groups are all still unknown, and none of them can be measured from a
/// Windows machine. The only way any of it comes back is the user copying this
/// text out of the app.
@MainActor
final class PhotoScanLog: ObservableObject {

    static let shared = PhotoScanLog()

    static let maxRuns = 20
    static let maxLinesPerRun = 300

    @Published private(set) var runs: [PhotoScanRun] = []

    private var loaded = false
    /// Every line used to write the whole store back out, and one delete
    /// writes one line per photo: 300 photos meant 300 encodes of 20 runs and
    /// 300 atomic writes, with a copy of `runs` queued up for each. Lines are
    /// gathered for this long instead, and anything that might be the last
    /// thing to happen flushes by hand.
    private static let writeInterval: TimeInterval = 0.5
    private var lastWrite = Date.distantPast
    private var writePending = false

    /// Called once per visit to the screen, so the numbering counts openings
    /// rather than processes.
    func beginRun() {
        loadIfNeeded()
        let number = (runs.last?.number ?? 0) + 1
        runs.append(PhotoScanRun(number: number,
                                 startedAt: Date(),
                                 build: AppVersion.short,
                                 lines: []))
        if runs.count > Self.maxRuns {
            runs.removeFirst(runs.count - Self.maxRuns)
        }
        // Not coalesced: the run header is what tells the next launch that
        // this one happened at all.
        write()
    }

    func note(_ text: String) {
        loadIfNeeded()
        guard var run = runs.last else { return }
        if run.lines.count == Self.maxLinesPerRun {
            run.lines.append(PhotoScanLogLine(at: Date(), text: "(これ以降は省略しました)"))
        } else if run.lines.count > Self.maxLinesPerRun {
            return
        } else {
            run.lines.append(PhotoScanLogLine(at: Date(), text: text))
        }
        runs[runs.count - 1] = run
        save()
    }

    /// Newest first: the run being asked about is almost always the last one.
    var newestFirst: [PhotoScanRun] { runs.reversed() }

    var allText: String {
        var out: [String] = []
        for run in newestFirst {
            out.append("=== \(run.label) ===")
            if run.lines.isEmpty {
                out.append("(記録なし)")
            } else {
                for line in run.lines {
                    out.append("\(PhotoScanFormat.stamp(line.at))  \(line.text)")
                }
            }
            out.append("")
        }
        if out.isEmpty { return "まだ記録がありません" }
        return out.joined(separator: "\n")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        runs = PhotoScanLogFile.load()
    }

    /// Written out at once, whatever the gathering above would have decided.
    /// Called wherever the next thing to happen might be the app going away:
    /// a scan finishing, photos being deleted, the screen being closed. When
    /// in doubt this is the safe side to err on -- a log that was never
    /// written is the one thing that cannot be recovered from a Windows
    /// machine.
    func flush() {
        guard loaded else { return }
        write()
    }

    private func save() {
        let since = Date().timeIntervalSince(lastWrite)
        guard since < Self.writeInterval else {
            write()
            return
        }
        guard !writePending else { return }
        writePending = true
        let delay = max(Self.writeInterval - since, 0.05)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.writePending else { return }
            self.write()
        }
    }

    private func write() {
        writePending = false
        lastWrite = Date()
        PhotoScanLogFile.save(runs)
    }

}

enum PhotoScanLogFile {

    private static let name = "photoscan-log.json"
    private static let queue = DispatchQueue(label: "jp.kaba.imagesaver.photoscanlog", qos: .utility)

    static func load() -> [PhotoScanRun] {
        guard let url = PhotoScanStore.url(name),
              let data = try? Data(contentsOf: url),
              let runs = try? PhotoScanStore.decoder().decode([PhotoScanRun].self, from: data)
        else { return [] }
        return runs
    }

    /// A lost log line costs nothing that cannot be produced again by running
    /// the scan once more, so this failure -- unlike a rejected pair -- is
    /// allowed to pass quietly.
    static func save(_ runs: [PhotoScanRun]) {
        queue.async {
            guard let url = PhotoScanStore.url(name),
                  let data = try? PhotoScanStore.encoder().encode(runs) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
