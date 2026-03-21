import Foundation

/// Purges old recordings and metadata files on a weekly schedule.
final class RecordingCleanup {
    private let recordingsDir: String
    private let maxAgeDays: Int
    private var timer: DispatchSourceTimer?

    init(
        recordingsDir: String = NSString("~/Meetings/recordings").expandingTildeInPath,
        maxAgeDays: Int = 7
    ) {
        self.recordingsDir = recordingsDir
        self.maxAgeDays = maxAgeDays
    }

    /// Run cleanup immediately and schedule weekly repeats
    func start() {
        // Run once on launch
        purge()

        // Then repeat daily (catches files that age out between weekly runs)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 86400, repeating: 86400) // every 24 hours
        timer.setEventHandler { [weak self] in
            self?.purge()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Delete WAV and JSON files older than maxAgeDays
    func purge() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)

        guard let files = try? fileManager.contentsOfDirectory(atPath: recordingsDir) else {
            return
        }

        var purgedCount = 0
        var freedBytes: UInt64 = 0

        for file in files {
            let ext = (file as NSString).pathExtension.lowercased()
            guard ext == "wav" || ext == "json" else { continue }

            let fullPath = (recordingsDir as NSString).appendingPathComponent(file)
            guard let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date else { continue }

            if modified < cutoff {
                let size = (attrs[.size] as? UInt64) ?? 0
                do {
                    try fileManager.removeItem(atPath: fullPath)
                    purgedCount += 1
                    freedBytes += size
                } catch {
                    fputs("[cleanup] Failed to delete \(file): \(error)\n", stderr)
                }
            }
        }

        if purgedCount > 0 {
            let freedMB = Double(freedBytes) / 1_048_576
            fputs("[cleanup] Purged \(purgedCount) files older than \(maxAgeDays) days (freed \(String(format: "%.1f", freedMB))MB)\n", stderr)
        }
    }
}
