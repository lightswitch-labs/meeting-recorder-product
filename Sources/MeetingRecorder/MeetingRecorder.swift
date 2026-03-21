import AppKit
import Foundation

@main
struct MeetingRecorder {
    static func main() {
        let args = CommandLine.arguments

        // CLI mode: meeting-recorder --cli [--pid 12345] [--sample-rate 48000]
        if args.contains("--cli") {
            runCLI(args: args)
            return
        }

        // Default: menu bar app mode
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// Original CLI mode for quick manual recordings
    static func runCLI(args: [String]) {
        var targetPID: Int32? = nil
        if let pidIndex = args.firstIndex(of: "--pid"), pidIndex + 1 < args.count {
            targetPID = Int32(args[pidIndex + 1])
        }

        var sampleRate: Double = 16000
        if let srIndex = args.firstIndex(of: "--sample-rate"), srIndex + 1 < args.count {
            sampleRate = Double(args[srIndex + 1]) ?? 16000
        }

        let config = AppConfig.load() ?? AppConfig.makeDefault()
        let outputDir = config.recordingsDir

        fputs("Meeting Recorder (CLI mode)\n", stderr)
        fputs("  Sample rate: \(Int(sampleRate))Hz\n", stderr)
        fputs("  Press Ctrl+C to stop recording\n\n", stderr)

        do {
            let session = try RecordingSession(
                outputDir: outputDir,
                meetingApp: "cli",
                entity: "general",
                meetingTitle: "CLI Recording",
                sampleRate: sampleRate,
                pids: targetPID != nil ? [targetPID!] : []
            )
            try session.start()

            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            sigintSource.setEventHandler {
                let result = session.stop()
                fputs("Recording saved: \(result.path) (\(result.durationMinutes)min)\n", stderr)
                exit(0)
            }
            sigintSource.resume()

            dispatchMain()
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }
}
