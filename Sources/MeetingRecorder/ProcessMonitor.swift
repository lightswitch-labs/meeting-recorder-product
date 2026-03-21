import AppKit
import CoreAudio
import Foundation

/// Monitors running processes to detect active meetings.
///
/// Detection strategy varies by app:
/// - **Zoom:** CptHost process monitoring — Zoom spawns CptHost when joining a call
///   and kills it when leaving. Deterministic binary signal with no ambiguity.
/// - **All others:** Calendar trigger or manual start from menu bar.
///
/// Pauses polling after system wake to avoid false triggers from stale process state.
final class ProcessMonitor {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.meetingrecorder.processmonitor")
    private let pollInterval: TimeInterval
    private var onMeetingDetected: ((DetectedMeeting) -> Void)?
    private var onMeetingEnded: ((MeetingApp) -> Void)?
    private var activeMeeting: DetectedMeeting?

    /// For non-Zoom apps: consecutive polls where all signals (mic, audio, camera) are idle
    private var allIdleCount = 0
    private let allIdleThreshold: Int  // polls before ending (2 min at 3s = 40 polls)

    /// Sleep/wake handling — pause polling after wake to let system stabilize
    private var lastWakeTime: Date = .distantPast
    private let wakeGracePeriod: TimeInterval = 30  // seconds to wait after wake
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    init(pollInterval: TimeInterval = 3.0, endTimeoutSeconds: TimeInterval = 120) {
        self.pollInterval = pollInterval
        self.allIdleThreshold = Int(endTimeoutSeconds / pollInterval)
    }

    func start(
        onDetected: @escaping (DetectedMeeting) -> Void,
        onEnded: @escaping (MeetingApp) -> Void
    ) {
        self.onMeetingDetected = onDetected
        self.onMeetingEnded = onEnded

        observeSleepWake()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
        fputs("[process-monitor] Started (polling every \(pollInterval)s)\n", stderr)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        activeMeeting = nil
        allIdleCount = 0
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObserver = nil
        sleepObserver = nil
        fputs("[process-monitor] Stopped\n", stderr)
    }

    func getActiveMeeting() -> DetectedMeeting? {
        return activeMeeting
    }

    // MARK: - Sleep/Wake Handling

    private func observeSleepWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.lastWakeTime = Date()
            fputs("[process-monitor] System woke — pausing detection for \(Int(self.wakeGracePeriod))s\n", stderr)

            // If there was an active recording when sleep happened, stop it
            if self.activeMeeting != nil {
                self.endMeeting(reason: "system sleep/wake")
            }
        }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            fputs("[process-monitor] System sleeping\n", stderr)
            // Stop any active recording before sleep
            if self?.activeMeeting != nil {
                self?.endMeeting(reason: "system going to sleep")
            }
        }
    }

    private var isInWakeGracePeriod: Bool {
        return Date().timeIntervalSince(lastWakeTime) < wakeGracePeriod
    }

    // MARK: - Main Poll Loop

    private func poll() {
        // Don't poll during wake grace period — window state and permissions are unstable
        if isInWakeGracePeriod {
            return
        }

        let runningApps = NSWorkspace.shared.runningApplications

        // Find all running meeting apps
        var candidates: [(app: MeetingApp, pids: [pid_t], isFrontmost: Bool)] = []
        for meetingApp in MeetingApp.allCases {
            let matchingApps = runningApps.filter { $0.bundleIdentifier == meetingApp.rawValue }
            if !matchingApps.isEmpty {
                let pids = matchingApps.map { $0.processIdentifier }
                let isFrontmost = matchingApps.contains { $0.isActive }
                candidates.append((app: meetingApp, pids: pids, isFrontmost: isFrontmost))
            }
        }

        // If we have an active meeting, check if it should end
        if let active = activeMeeting {
            let stillRunning = candidates.contains { $0.app == active.app }

            if !stillRunning {
                endMeeting(reason: "app quit")
                return
            }

            if active.app.supportsProcessBasedDetection {
                checkZoomMeetingEnd()
            } else {
                checkComboMeetingEnd(active: active)
            }
            return
        }

        // No active meeting — check if we should start one
        for candidate in candidates {
            if candidate.app.supportsProcessBasedDetection {
                if isZoomCptHostRunning() {
                    startMeeting(app: candidate.app, pids: candidate.pids, method: "CptHost process")
                    return
                }
            }
        }

        // Non-Zoom apps: no automatic start trigger.
        // Mic/camera-based detection causes circular activation (our own mic usage
        // triggers the detector). These meetings are handled via:
        // - Calendar trigger (scheduled meetings)
        // - Manual start from menu bar (ad-hoc calls)
    }

    // MARK: - Meeting Start/End

    private func startMeeting(app: MeetingApp, pids: [pid_t], method: String) {
        let meeting = DetectedMeeting(app: app, pids: pids, detectedAt: Date())
        activeMeeting = meeting
        allIdleCount = 0
        fputs("[process-monitor] Meeting started: \(app.displayName) (PIDs: \(pids), detected via: \(method))\n", stderr)
        DispatchQueue.main.async { [weak self] in
            self?.onMeetingDetected?(meeting)
        }
    }

    private func endMeeting(reason: String) {
        guard let active = activeMeeting else { return }
        fputs("[process-monitor] Meeting ended (\(reason)): \(active.app.displayName)\n", stderr)
        activeMeeting = nil
        allIdleCount = 0
        DispatchQueue.main.async { [weak self] in
            self?.onMeetingEnded?(active.app)
        }
    }

    // MARK: - Zoom: CptHost Process Detection

    /// Check if Zoom's CptHost process is running.
    /// CptHost is spawned when joining a call and killed when leaving.
    /// This is a deterministic signal — no window titles, no mic/camera checks needed.
    private func isZoomCptHostRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "CptHost"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            fputs("[process-monitor] pgrep failed: \(error)\n", stderr)
            return false
        }
    }

    /// End detection for Zoom: CptHost gone = call ended.
    private func checkZoomMeetingEnd() {
        if !isZoomCptHostRunning() {
            endMeeting(reason: "CptHost process exited — Zoom call ended")
        }
    }

    // MARK: - Combo Detection: Mic OR Audio OR Camera

    private func checkComboMeetingEnd(active: DetectedMeeting) {
        let micActive = isMicrophoneInUse()
        let cameraActive = isCameraInUse()

        if !micActive && !cameraActive {
            allIdleCount += 1
            let secondsIdle = Int(Double(allIdleCount) * pollInterval)
            let secondsThreshold = Int(Double(allIdleThreshold) * pollInterval)
            if allIdleCount >= allIdleThreshold {
                endMeeting(reason: "all signals idle for \(secondsThreshold)s")
            } else if allIdleCount % 10 == 1 {
                fputs("[process-monitor] All signals idle for \(secondsIdle)s / \(secondsThreshold)s\n", stderr)
            }
        } else {
            if allIdleCount > 0 {
                fputs("[process-monitor] Signal resumed (mic:\(micActive) camera:\(cameraActive)) — reset idle counter\n", stderr)
            }
            allIdleCount = 0
        }
    }

    // MARK: - Hardware Checks

    private func isMicrophoneInUse() -> Bool {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return false }

        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let runningStatus = AudioObjectGetPropertyData(
            deviceID, &runningAddress, 0, nil, &runningSize, &isRunning
        )
        return runningStatus == noErr && isRunning > 0
    }

    private func isCameraInUse() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { app in
            guard let name = app.localizedName else { return false }
            return name == "VDCAssistant" || name == "AppleCameraAssistant"
        }
    }
}
