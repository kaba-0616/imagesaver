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
    /// A video's thumbnail rather than a picture of its own. Instagram serves
    /// these from the same CDN under the same naming as photographs, so the
    /// only thing that separates them is their tie to a <video> in the DOM.
    let isVideoPoster: Bool

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
