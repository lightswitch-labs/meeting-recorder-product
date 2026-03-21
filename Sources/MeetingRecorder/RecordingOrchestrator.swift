import Foundation

/// Orchestrates meeting detection and recording.
/// Connects ProcessMonitor + CalendarTrigger → RecordingSession → Pipeline Handoff.
final class RecordingOrchestrator {
    private let processMonitor = ProcessMonitor()
    private let calendarTrigger = CalendarTrigger()
    private var activeSession: RecordingSession?
    private let outputDir: String
    private let sampleRate: Double
    private let silenceTimeout: TimeInterval
    private var onRecordingComplete: ((RecordingResult) -> Void)?
    private var onStatusChange: ((RecorderStatus) -> Void)?

    // Track calendar context for entity/title detection
    private var pendingCalendarMeeting: CalendarMeeting?

    init(
        outputDir: String = NSString("~/Meetings/recordings").expandingTildeInPath,
        sampleRate: Double = 16000,
        silenceTimeout: TimeInterval = 60
    ) {
        self.outputDir = outputDir
        self.sampleRate = sampleRate
        self.silenceTimeout = silenceTimeout
    }

    func start(
        onRecordingComplete: @escaping (RecordingResult) -> Void,
        onStatusChange: @escaping (RecorderStatus) -> Void
    ) {
        self.onRecordingComplete = onRecordingComplete
        self.onStatusChange = onStatusChange

        // Start process monitor
        processMonitor.start(
            onDetected: { [weak self] meeting in
                self?.handleMeetingAppDetected(meeting)
            },
            onEnded: { [weak self] app in
                self?.handleMeetingAppEnded(app)
            }
        )

        // Start calendar trigger
        calendarTrigger.start(
            onUpcoming: { [weak self] meeting in
                self?.handleCalendarMeeting(meeting)
            },
            onEnded: { [weak self] meeting in
                self?.handleCalendarMeetingEnded(meeting)
            }
        )

        onStatusChange(.idle)
        fputs("[orchestrator] Started — monitoring for meetings\n", stderr)
    }

    func stop() {
        processMonitor.stop()
        calendarTrigger.stop()
        if let session = activeSession {
            let result = session.stop()
            activeSession = nil
            onRecordingComplete?(result)
        }
        onStatusChange?(.idle)
    }

    /// Manual start recording (menu bar override)
    func manualStart() {
        guard activeSession == nil else {
            fputs("[orchestrator] Already recording — ignoring manual start\n", stderr)
            return
        }

        do {
            let session = try RecordingSession(
                outputDir: outputDir,
                meetingApp: "manual",
                entity: EntityDetector.defaultEntity,
                meetingTitle: "Manual Recording",
                sampleRate: sampleRate
            )
            session.silenceTimeout = silenceTimeout
            session.onSilenceTimeout = { [weak self] in
                self?.stopRecording()
            }
            try session.start()
            activeSession = session
            onStatusChange?(.recording(app: "Manual", title: "Manual Recording"))
        } catch {
            fputs("[orchestrator] Manual start failed: \(error)\n", stderr)
        }
    }

    /// Manual stop recording (menu bar override)
    func manualStop() {
        stopRecording()
    }

    var isRecording: Bool {
        return activeSession?.isRecording ?? false
    }

    // MARK: - Meeting Detection Handlers

    private func handleMeetingAppDetected(_ meeting: DetectedMeeting) {
        guard activeSession == nil else {
            fputs("[orchestrator] Already recording — ignoring \(meeting.app.displayName) detection\n", stderr)
            return
        }

        // Use calendar context if available, otherwise defaults
        let calendarMeeting = pendingCalendarMeeting
        let entity = calendarMeeting.map { EntityDetector.detect(from: $0) } ?? EntityDetector.defaultEntity
        let title = calendarMeeting?.title ?? "\(meeting.app.displayName) Meeting"
        let attendees = calendarMeeting?.attendees ?? []

        do {
            let session = try RecordingSession(
                outputDir: outputDir,
                meetingApp: meeting.app.displayName,
                entity: entity,
                meetingTitle: title,
                attendees: attendees,
                sampleRate: sampleRate,
                pids: meeting.pids
            )
            session.silenceTimeout = silenceTimeout
            session.onSilenceTimeout = { [weak self] in
                self?.stopRecording()
            }
            try session.start()
            activeSession = session
            onStatusChange?(.recording(app: meeting.app.displayName, title: title))
        } catch {
            fputs("[orchestrator] Failed to start recording: \(error)\n", stderr)
        }
    }

    private func handleMeetingAppEnded(_ app: MeetingApp) {
        guard activeSession != nil else { return }
        fputs("[orchestrator] Meeting app ended — stopping recording\n", stderr)
        stopRecording()
    }

    private func handleCalendarMeeting(_ meeting: CalendarMeeting) {
        fputs("[orchestrator] Calendar meeting upcoming: \"\(meeting.title)\"\n", stderr)
        pendingCalendarMeeting = meeting

        // For browser-based meetings, start recording on calendar trigger
        // (we can't reliably detect Google Meet via process monitoring)
        if meeting.isBrowserBased && activeSession == nil {
            let entity = EntityDetector.detect(from: meeting)
            do {
                let session = try RecordingSession(
                    outputDir: outputDir,
                    meetingApp: "Google Meet",
                    entity: entity,
                    meetingTitle: meeting.title,
                    attendees: meeting.attendees,
                    sampleRate: sampleRate,
                    isBrowserBased: true
                )
                session.silenceTimeout = silenceTimeout
                session.onSilenceTimeout = { [weak self] in
                    self?.stopRecording()
                }
                try session.start()
                activeSession = session
                onStatusChange?(.recording(app: "Google Meet", title: meeting.title))
            } catch {
                fputs("[orchestrator] Failed to start browser meeting recording: \(error)\n", stderr)
            }
        }
    }

    private func handleCalendarMeetingEnded(_ meeting: CalendarMeeting) {
        pendingCalendarMeeting = nil
        if meeting.isBrowserBased && activeSession != nil {
            fputs("[orchestrator] Calendar meeting ended — stopping recording\n", stderr)
            stopRecording()
        }
    }

    private func stopRecording() {
        guard let session = activeSession else { return }
        let result = session.stop()
        activeSession = nil
        pendingCalendarMeeting = nil
        onStatusChange?(.idle)
        onRecordingComplete?(result)
    }
}

enum RecorderStatus {
    case idle
    case recording(app: String, title: String)
}
