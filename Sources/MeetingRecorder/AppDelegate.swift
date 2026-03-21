import AppKit
import Foundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var orchestrator: RecordingOrchestrator!
    private var handoff: PipelineHandoff!
    private var cleanup: RecordingCleanup!
    private var config: AppConfig!

    // Menu items that need dynamic updates
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var meetingTitleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Check if onboarding is needed
        if let existingConfig = AppConfig.load(), existingConfig.onboardingComplete {
            config = existingConfig
            startApp()
        } else {
            OnboardingWizard.run { [weak self] result in
                switch result {
                case .completed(let newConfig):
                    self?.config = newConfig
                    self?.startApp()
                case .cancelled:
                    fputs("[app] Onboarding cancelled — quitting\n", stderr)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func startApp() {
        // Build menu bar first so it's visible during permission check
        setupMenuBar()

        // Defer permission check — avoid activating mic indicator on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            PermissionChecker.check { status in
                PermissionChecker.alertIfNeeded(status)
            }
        }

        // Set up recording cleanup (purge files older than 7 days)
        cleanup = RecordingCleanup(recordingsDir: config.recordingsDir)
        cleanup.start()

        // Set up pipeline handoff
        handoff = PipelineHandoff()

        // Set up orchestrator
        orchestrator = RecordingOrchestrator(outputDir: config.recordingsDir)
        orchestrator.start(
            onRecordingComplete: { [weak self] result in
                self?.handleRecordingComplete(result)
            },
            onStatusChange: { [weak self] status in
                self?.updateMenuBar(status: status)
            }
        )

        fputs("[app] Meeting Recorder started (recordings: \(config.recordingsDir))\n", stderr)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Meeting Recorder")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        // Status line
        statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Meeting title (hidden when idle)
        meetingTitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        meetingTitleItem.isEnabled = false
        meetingTitleItem.isHidden = true
        menu.addItem(meetingTitleItem)

        menu.addItem(NSMenuItem.separator())

        // Toggle recording
        toggleMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Open folders
        let recordingsItem = NSMenuItem(title: "Open Recordings Folder", action: #selector(openRecordingsFolder), keyEquivalent: "o")
        recordingsItem.target = self
        menu.addItem(recordingsItem)

        let transcriptsItem = NSMenuItem(title: "Open Transcripts Folder", action: #selector(openTranscriptsFolder), keyEquivalent: "t")
        transcriptsItem.target = self
        menu.addItem(transcriptsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Meeting Recorder", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateMenuBar(status: RecorderStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch status {
            case .idle:
                let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Meeting Recorder — Idle")
                image?.isTemplate = true
                self.statusItem.button?.image = image
                self.statusItem.button?.contentTintColor = nil
                self.statusMenuItem.title = "Status: Idle"
                self.meetingTitleItem.isHidden = true
                self.toggleMenuItem.title = "Start Recording"
                fputs("[ui] Menu bar → idle\n", stderr)

            case .recording(let app, let title):
                // Create a small red circle as the recording indicator
                let size = NSSize(width: 18, height: 18)
                let image = NSImage(size: size, flipped: false) { rect in
                    NSColor.systemRed.setFill()
                    let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
                    circle.fill()
                    return true
                }
                image.isTemplate = false
                self.statusItem.button?.image = image
                self.statusItem.button?.contentTintColor = nil
                self.statusMenuItem.title = "Status: Recording (\(app))"
                self.meetingTitleItem.title = title
                self.meetingTitleItem.isHidden = false
                self.toggleMenuItem.title = "Stop Recording"
                fputs("[ui] Menu bar → recording (\(app): \(title))\n", stderr)
            }
        }
    }

    private func handleRecordingComplete(_ result: RecordingResult) {
        fputs("[app] Recording complete: \(result.path) (\(result.durationMinutes)min)\n", stderr)

        // Confirm entity and meeting title before transcription
        EntityConfirmation.confirm(
            detectedEntity: result.entity,
            meetingTitle: result.meetingTitle
        ) { [weak self] confirmation in
            switch confirmation {
            case .confirmed(let entity, let meetingTitle):
                // Rename the file to include the confirmed meeting title
                let finalPath = self?.renameRecording(at: result.path, title: meetingTitle) ?? result.path

                let confirmedResult = RecordingResult(
                    path: finalPath,
                    duration: result.duration,
                    meetingApp: result.meetingApp,
                    entity: entity,
                    meetingTitle: meetingTitle,
                    attendees: result.attendees,
                    sampleRate: result.sampleRate
                )
                self?.handoff.process(confirmedResult)
            case .skipped:
                fputs("[app] Transcription skipped by user\n", stderr)
            }
        }
    }

    /// Rename a recording file to include the meeting title slug.
    /// e.g., `2026-03-20_14-30.wav` → `2026-03-20_14-30_weekly-standup.wav`
    private func renameRecording(at path: String, title: String) -> String {
        let slug = title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        guard !slug.isEmpty else { return path }

        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let newPath = "\(dir)/\(stem)_\(slug).\(ext)"

        do {
            try FileManager.default.moveItem(atPath: path, toPath: newPath)
            fputs("[app] Renamed recording: \(URL(fileURLWithPath: newPath).lastPathComponent)\n", stderr)
            return newPath
        } catch {
            fputs("[app] Failed to rename recording: \(error)\n", stderr)
            return path
        }
    }

    @objc private func toggleRecording() {
        if orchestrator.isRecording {
            orchestrator.manualStop()
        } else {
            orchestrator.manualStart()
        }
    }

    @objc private func openRecordingsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: config.recordingsDir))
    }

    @objc private func openTranscriptsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: config.transcriptsDir))
    }

    @objc private func quit() {
        orchestrator?.stop()
        cleanup?.stop()
        NSApp.terminate(nil)
    }
}
