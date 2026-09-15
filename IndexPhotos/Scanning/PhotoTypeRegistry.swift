import Foundation

enum PhotoTypeRegistry {
    private static let extensions: Set<String> = [
        "arw", "avif", "bmp", "cr2", "cr3", "dng", "gif", "heic", "heif",
        "jpeg", "jpg", "nef", "orf", "png", "raf", "raw", "rw2", "tif", "tiff",
        "webp"
    ]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
