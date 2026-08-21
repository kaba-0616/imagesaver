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
    /// Named only by the page's og:image / twitter:image tags. A single-page
    /// app does not rewrite those as you navigate, so this can be a picture
    /// from whichever page was served first.
    let isPageMetaImage: Bool
    /// Nested inside a link pointing at a different page -- on Instagram, the
    /// "more posts" thumbnails under a post. Same CDN, same naming and often
    /// the same size as the slides themselves, so only the surrounding markup
    /// separates them.
    let isOtherPostImage: Bool

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
