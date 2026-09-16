import Foundation

enum PhotoTypeRegistry {
    private static let extensions: Set<String> = [
        "arw", "avif", "bmp", "cr2", "cr3", "dng", "gif", "heic", "heif",
        "jpeg", "jpg", "nef", "orf", "png", "raf", "raw", "rw2", "tif", "tiff",
        "webp"
    ]
    private static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "dng", "nef", "orf", "raf", "raw", "rw2"
    ]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func isRaw(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    static func siblingKey(for url: URL) -> String {
        let directory = url.deletingLastPathComponent()
            .standardizedFileURL
            .path
        let stem = url.deletingPathExtension()
            .lastPathComponent
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return "\(directory)\u{0000}\(stem)"
    }
}
