import CoreGraphics
import Foundation

/// One photo this feature found a margin worth trimming on.
struct MarginCropCandidate: Identifiable, Equatable {
    let localIdentifier: String
    let width: Int
    let height: Int
    let creationDate: Date?
    var byteCount: Int64? = nil
    let margin: MarginResult

    var id: String { localIdentifier }

    var cropRect: CGRect { margin.cropRect(width: width, height: height) }

    /// "上下"/"左右"/"四辺" -- whichever edges actually carry a margin.
    var badgeLabel: String {
        let vertical = margin.top > 0 || margin.bottom > 0
        let horizontal = margin.left > 0 || margin.right > 0
        switch (vertical, horizontal) {
        case (true, true): return "四辺"
        case (true, false): return "上下"
        case (false, true): return "左右"
        case (false, false): return ""
        }
    }
}
