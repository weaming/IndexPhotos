import Darwin
import Dispatch
import Foundation

@main
struct ScanBenchmark {
    static func main() async {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count == 4, let timeoutSeconds = Double(args[3]), timeoutSeconds > 0 else {
            fputs("用法：scan-benchmark <照片目录> <独立缓存目录> <超时秒数>\n", stderr)
            exit(1)
        }

        do {
            let rootURL = URL(fileURLWithPath: args[1], isDirectory: true)
            let cacheURL = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            let catalog = try CatalogStore(databaseURL: cacheURL.appendingPathComponent("catalog.sqlite"))
            let rootID = StableIdentifier.rootID(for: rootURL)
            try await catalog.upsertRoot(id: rootID, displayName: "benchmark", url: rootURL, bookmarkData: nil)
            let coordinator = ScanCoordinator(
                catalog: catalog,
                thumbnailStore: ThumbnailStore(storageDirectory: cacheURL)
            )
            let clock = ContinuousClock()
            let startedAt = clock.now
            let deadline = DispatchSource.makeTimerSource(queue: DispatchQueue(
                label: "scan-benchmark.timeout",
                qos: .userInteractive
            ))
            deadline.schedule(deadline: .now() + timeoutSeconds)
            deadline.setEventHandler {
                print("BENCH timeout seconds=\(timeoutSeconds)")
                _exit(124)
            }
            deadline.resume()
            let run = try await coordinator.start(rootID: rootID, rootURL: rootURL)
            var lastReportAt = startedAt
            var finalProgress = ScanProgressSnapshot.idle
            for await progress in run.updates {
                finalProgress = progress
                let now = clock.now
                if lastReportAt.duration(to: now) >= .seconds(1) || progress.status != .running {
                    let elapsed = startedAt.duration(to: now)
                    let stats = transferStats(
                        processedBytes: progress.processedBytes,
                        elapsed: elapsed
                    )
                    print(
                        "BENCH phase=\(progress.phase.rawValue) status=\(progress.status.rawValue) files=\(progress.committedCount) failed=\(progress.failedCount) \(stats) elapsed=\(elapsed)"
                    )
                    lastReportAt = now
                }
            }
            deadline.cancel()
            let summary = try await catalog.resultSummary()
            let elapsed = startedAt.duration(to: clock.now)
            let stats = transferStats(processedBytes: finalProgress.processedBytes, elapsed: elapsed)
            print(
                "BENCH result status=\(finalProgress.status.rawValue) files=\(finalProgress.committedCount) failed=\(finalProgress.failedCount) groups=\(summary.duplicateGroupCount) candidates=\(summary.similarityCandidateCount) \(stats) elapsed=\(elapsed)"
            )
            if let error = finalProgress.lastError {
                print("BENCH error=\(error)")
            }
            try await catalog.close()
            if finalProgress.status != .completed {
                exit(1)
            }
        } catch {
            fputs("扫描基准失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func transferStats(processedBytes: Int64, elapsed: Duration) -> String {
        let processedMB = Double(processedBytes) / 1_000_000
        let components = elapsed.components
        let elapsedSeconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let avgMBps = elapsedSeconds > 0 ? processedMB / elapsedSeconds : 0

        return String(
            format: "bytes=%.2fMB avg=%.2fMB/s",
            locale: Locale(identifier: "en_US_POSIX"),
            processedMB,
            avgMBps
        )
    }
}
