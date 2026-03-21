import Foundation

/// Handles post-recording actions: metadata sidecar + transcription pipeline invocation.
/// Uses bundled call-analyzer.py, Keychain for API key, and AppConfig for output paths.
final class PipelineHandoff {

    /// Process a completed recording: write metadata and invoke transcription pipeline.
    func process(_ result: RecordingResult) {
        writeMetadataSidecar(result)
        invokeTranscriptionPipeline(result)
    }

    private func writeMetadataSidecar(_ result: RecordingResult) {
        let jsonPath = result.path.replacingOccurrences(of: ".wav", with: ".json")
        do {
            try result.metadataJSON.write(toFile: jsonPath, atomically: true, encoding: .utf8)
            fputs("[handoff] Metadata written: \(jsonPath)\n", stderr)
        } catch {
            fputs("[handoff] Failed to write metadata: \(error)\n", stderr)
        }
    }

    private func invokeTranscriptionPipeline(_ result: RecordingResult) {
        // Skip very short recordings (likely false triggers)
        guard result.duration >= 30 else {
            fputs("[handoff] Recording too short (\(Int(result.duration))s) — skipping transcription\n", stderr)
            return
        }

        // Load config for output directory
        guard let config = AppConfig.load() else {
            fputs("[handoff] No config found — skipping transcription\n", stderr)
            return
        }

        // Load API key from Keychain
        guard let apiKey = KeychainHelper.load(key: KeychainHelper.assemblyAIKey) else {
            fputs("[handoff] No AssemblyAI API key in Keychain — skipping transcription\n", stderr)
            sendNotification(
                title: "Transcription Skipped",
                body: "No AssemblyAI API key configured. Add it in Settings."
            )
            return
        }

        // Locate bundled call-analyzer.py
        let analyzerPath = bundledAnalyzerPath()
        guard FileManager.default.fileExists(atPath: analyzerPath) else {
            fputs("[handoff] call-analyzer.py not found at \(analyzerPath)\n", stderr)
            return
        }

        fputs("[handoff] Invoking call-analyzer.py for \(result.meetingApp) meeting (\(result.durationMinutes)min)\n", stderr)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")

        var arguments = [
            analyzerPath,
            result.path,
            "--entity", result.entity,
            "--output-dir", config.transcriptsDir,
        ]

        if !result.meetingTitle.isEmpty && result.meetingTitle != "Manual Recording" {
            arguments += ["--meeting-name", result.meetingTitle]
        }

        if !result.attendees.isEmpty {
            arguments += ["--attendees", result.attendees.joined(separator: ",")]
        }

        process.arguments = arguments

        // Pass API key via environment (not CLI arg — more secure)
        var env = ProcessInfo.processInfo.environment
        env["ASSEMBLYAI_API_KEY"] = apiKey
        process.environment = env

        // Capture stdout and stderr for debugging
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Run in background — don't block the recorder
        DispatchQueue.global().async {
            do {
                try process.run()
                fputs("[handoff] Pipeline started (PID: \(process.processIdentifier))\n", stderr)
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    fputs("[handoff] Transcription complete for: \(result.meetingTitle)\n", stderr)
                    if !stdout.isEmpty {
                        fputs("[handoff] Output: \(stdout.prefix(500))\n", stderr)
                    }
                    self.sendNotification(
                        title: "Meeting Transcribed",
                        body: "\"\(result.meetingTitle)\" (\(result.durationMinutes)min) — \(result.entity)"
                    )
                } else {
                    fputs("[handoff] Transcription FAILED (exit code \(process.terminationStatus))\n", stderr)
                    if !stdout.isEmpty {
                        fputs("[handoff] stdout: \(stdout.prefix(1000))\n", stderr)
                    }
                    if !stderrOutput.isEmpty {
                        fputs("[handoff] stderr: \(stderrOutput.prefix(1000))\n", stderr)
                    }
                    self.sendNotification(
                        title: "Transcription Failed",
                        body: "\"\(result.meetingTitle)\" — exit code \(process.terminationStatus)"
                    )
                }
            } catch {
                fputs("[handoff] Failed to invoke pipeline: \(error)\n", stderr)
                self.sendNotification(
                    title: "Transcription Failed",
                    body: "\"\(result.meetingTitle)\" — \(error.localizedDescription)"
                )
            }
        }
    }

    /// Path to the bundled call-analyzer.py inside the .app bundle
    private func bundledAnalyzerPath() -> String {
        if let bundlePath = Bundle.main.path(forResource: "call-analyzer", ofType: "py") {
            return bundlePath
        }
        // Fallback: check next to the executable (for CLI mode / dev builds)
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? ""
        return (execDir as NSString).appendingPathComponent("call-analyzer.py")
    }

    private func sendNotification(title: String, body: String) {
        let script = """
        display notification "\(body)" with title "\(title)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
