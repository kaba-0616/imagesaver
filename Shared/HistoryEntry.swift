import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: String { pageURL }
    let pageURL: String
    let pageTitle: String
    let imageCount: Int
    let date: Date
}
