import Foundation

/// Handles post-recording actions: metadata sidecar + transcription pipeline invocation.
/// Authenticates via Google OAuth → key-vending service → AssemblyAI API key.
final class PipelineHandoff {

    private let keyVendingURL = "https://keys.lightswitchlabs.ai/api/key"

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

        // Get a fresh ID token via Google refresh token
        guard let refreshToken = KeychainHelper.load(key: KeychainHelper.googleRefreshToken) else {
            fputs("[handoff] No Google refresh token — user needs to sign in\n", stderr)
            sendNotification(
                title: "Transcription Skipped",
                body: "Not signed in. Open Meeting Recorder to sign in with Google."
            )
            return
        }

        fputs("[handoff] Refreshing Google token...\n", stderr)

        let semaphore = DispatchSemaphore(value: 0)
        var idToken: String?

        GoogleAuth.refresh(refreshToken: refreshToken) { tokens in
            idToken = tokens?.idToken
            semaphore.signal()
        }
        semaphore.wait()

        guard let token = idToken else {
            fputs("[handoff] Failed to refresh Google token — user may need to re-sign-in\n", stderr)
            sendNotification(
                title: "Transcription Skipped",
                body: "Google sign-in expired. Open Meeting Recorder to sign in again."
            )
            return
        }

        // Fetch API key from key-vending service
        fputs("[handoff] Fetching API key from key-vending service...\n", stderr)
        guard let apiKey = fetchAPIKey(idToken: token) else {
            return  // error already logged and notified
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
        ]

        if !result.meetingTitle.isEmpty && result.meetingTitle != "Manual Recording" {
            arguments += ["--meeting-name", result.meetingTitle]
        }

        if !result.attendees.isEmpty {
            arguments += ["--attendees", result.attendees.joined(separator: ",")]
        }

        process.arguments = arguments

        // Pass API key via environment
        var env = ProcessInfo.processInfo.environment
        env["ASSEMBLYAI_API_KEY"] = apiKey
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        DispatchQueue.global().async {
            do {
                try process.run()
                fputs("[handoff] Pipeline started (PID: \(process.processIdentifier))\n", stderr)
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""

                if !stderrOutput.isEmpty {
                    fputs("[handoff] Pipeline log:\n\(stderrOutput.prefix(2000))\n", stderr)
                }

                guard process.terminationStatus == 0 else {
                    fputs("[handoff] Transcription FAILED (exit code \(process.terminationStatus))\n", stderr)
                    self.sendNotification(
                        title: "Transcription Failed",
                        body: "\"\(result.meetingTitle)\" — exit code \(process.terminationStatus)"
                    )
                    return
                }

                // Parse JSON output from Python
                guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any],
                      let analysis = json["analysis"] as? String,
                      let dateStr = json["date"] as? String,
                      let slug = json["slug"] as? String,
                      let entity = json["entity"] as? String else {
                    fputs("[handoff] Failed to parse pipeline JSON output\n", stderr)
                    self.sendNotification(
                        title: "Transcription Failed",
                        body: "\"\(result.meetingTitle)\" — invalid pipeline output"
                    )
                    return
                }

                // Write the markdown file (Swift has file permissions, Python doesn't)
                let meetingsDir = (config.transcriptsDir as NSString)
                    .appendingPathComponent(entity)
                    .appending("/meetings")
                let filename = "\(dateStr)-\(slug).md"
                let outputPath = (meetingsDir as NSString).appendingPathComponent(filename)

                do {
                    try FileManager.default.createDirectory(
                        atPath: meetingsDir, withIntermediateDirectories: true
                    )
                    try (analysis + "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
                    fputs("[handoff] Analysis written to: \(outputPath)\n", stderr)
                } catch {
                    fputs("[handoff] Failed to write analysis file: \(error)\n", stderr)
                }

                self.sendNotification(
                    title: "Meeting Transcribed",
                    body: "\"\(result.meetingTitle)\" (\(result.durationMinutes)min) — \(result.entity)"
                )
            } catch {
                fputs("[handoff] Failed to invoke pipeline: \(error)\n", stderr)
                self.sendNotification(
                    title: "Transcription Failed",
                    body: "\"\(result.meetingTitle)\" — \(error.localizedDescription)"
                )
            }
        }
    }

    /// Fetch the AssemblyAI API key from the key-vending service using a Google ID token.
    private func fetchAPIKey(idToken: String) -> String? {
        guard let url = URL(string: keyVendingURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        var apiKey: String?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
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
                }
            } else if httpResponse.statusCode == 401 {
                fputs("[handoff] Key-vending: unauthorized — token invalid or expired\n", stderr)
                self.sendNotification(
                    title: "Transcription Skipped",
                    body: "Authentication failed. Try signing in again from the menu bar."
                )
            } else if httpResponse.statusCode == 403 {
                fputs("[handoff] Key-vending: access not authorized for this account\n", stderr)
                self.sendNotification(
                    title: "Access Not Authorized",
                    body: "Your Google account is not authorized to use this app. Contact the administrator."
                )
            } else {
                fputs("[handoff] Key-vending: unexpected status \(httpResponse.statusCode)\n", stderr)
                if let body = String(data: data, encoding: .utf8) {
                    fputs("[handoff] Response: \(body.prefix(500))\n", stderr)
                }
            }
        }.resume()

        semaphore.wait()
        return apiKey
    }

    private func bundledAnalyzerPath() -> String {
        if let bundlePath = Bundle.main.path(forResource: "call-analyzer", ofType: "py") {
            return bundlePath
        }
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
