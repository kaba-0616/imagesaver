import Foundation

enum HistoryStore {
    private static let key = "recentPages"
    private static let maxEntries = 10

    static func recordVisit(pageURL: String, pageTitle: String, imageCount: Int) {
        guard !pageURL.isEmpty else { return }
        var entries = load()
        entries.removeAll { $0.pageURL == pageURL }
        entries.insert(
            HistoryEntry(pageURL: pageURL, pageTitle: pageTitle, imageCount: imageCount, date: Date()),
            at: 0
        )
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save(entries)
    }

    static func load() -> [HistoryEntry] {
        guard let data = AppGroup.defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func save(_ entries: [HistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }
}
