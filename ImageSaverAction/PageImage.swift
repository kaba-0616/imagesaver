import Foundation

struct PageImage: Identifiable, Hashable {
    let id: Int
    let url: URL
    let width: Int
    let height: Int
    /// Found only in the page's markup text, not rendered by it. Often the
    /// full-resolution original, but on feed-style sites also a lot of images
    /// belonging to other posts.
    let isFromSourceOnly: Bool

    var formatLabel: String {
        switch url.pathExtension.lowercased() {
        case "heic", "heif": return "HEIF"
        case "webp": return "WebP"
        case "svg": return "SVG"
        case "gif": return "GIF"
        case "png": return "PNG"
        case "jpg", "jpeg": return "JPEG"
        default: return url.pathExtension.uppercased()
        }
    }

    var isSVG: Bool {
        url.pathExtension.lowercased() == "svg"
    }
}
