import Foundation

/// Handles post-recording actions: metadata sidecar + transcription pipeline invocation.
/// Fetches API key from the key-vending service using the user's access token.
final class PipelineHandoff {

    private let keyVendingURL = "https://meeting-recorder-keys.zaro-michael.workers.dev/api/key"

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

        // Load access token from Keychain
        guard let token = KeychainHelper.load(key: KeychainHelper.accessToken) else {
            fputs("[handoff] No access token in Keychain — skipping transcription\n", stderr)
            sendNotification(
                title: "Transcription Skipped",
                body: "No access token configured. Re-run setup or contact the app administrator."
            )
            return
        }

        // Fetch API key from key-vending service
        fputs("[handoff] Fetching API key from key-vending service...\n", stderr)
        guard let apiKey = fetchAPIKey(token: token) else {
            return  // error already logged and notified in fetchAPIKey
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

    /// Fetch the AssemblyAI API key from the key-vending service.
    /// Returns nil on failure (logs and notifies the user).
    private func fetchAPIKey(token: String) -> String? {
        guard let url = URL(string: keyVendingURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        var apiKey: String?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                fputs("[handoff] Key-vending request failed: \(error.localizedDescription)\n", stderr)
                self.sendNotification(
                    title: "Transcription Skipped",
                    body: "Could not reach the key service. Check your internet connection."
                )
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data = data else {
                fputs("[handoff] Key-vending: no response\n", stderr)
                return
            }

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let key = json["key"] as? String, !key.isEmpty {
                    apiKey = key
                    fputs("[handoff] API key fetched successfully\n", stderr)
                } else {
                    fputs("[handoff] Key-vending: invalid response body\n", stderr)
                }
            } else if httpResponse.statusCode == 401 {
                fputs("[handoff] Key-vending: unauthorized — invalid token\n", stderr)
                self.sendNotification(
                    title: "Transcription Skipped",
                    body: "Your access token is invalid. Contact the app administrator."
                )
            } else if httpResponse.statusCode == 403 {
                fputs("[handoff] Key-vending: token revoked\n", stderr)
                self.sendNotification(
                    title: "Access Revoked",
                    body: "Your access token has been revoked. Contact the app administrator."
                )
            } else {
                fputs("[handoff] Key-vending: unexpected status \(httpResponse.statusCode)\n", stderr)
            }
        }

        task.resume()
        semaphore.wait()

        return apiKey
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
