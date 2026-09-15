import Darwin
import Foundation

final class CacheLock: @unchecked Sendable {
    private let descriptor: Int32

    init(url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw IndexPhotosError.database("无法打开实例锁 \(url.path)：\(String(cString: strerror(errno)))")
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw IndexPhotosError.anotherInstanceIsRunning
        }

        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
