import AudioTeeCore
import AVFoundation
import Foundation

/// Manages a single recording session — from start to WAV file output.
/// Handles system audio capture (AudioTeeCore) + mic capture (AVAudioEngine) → stereo WAV.
final class RecordingSession {
    let outputPath: String
    let meetingApp: String
    let entity: String
    let meetingTitle: String
    let attendees: [String]
    let startTime: Date
    let sampleRate: Double

    private var wavWriter: WAVWriter?
    private var tapManager: AudioTapManager?
    private var recorder: AudioRecorder?
    private var micCapture: MicCapture?
    private var interleaveTimer: DispatchSourceTimer?

    private let lock = NSLock()
    private var systemBuffer = Data()
    private var micBuffer = Data()
    private var silenceStart: Date?
    private var lastAudioActivity: Date
    private(set) var isRecording = false

    /// Callback when silence timeout is reached
    var onSilenceTimeout: (() -> Void)?

    /// Silence duration before auto-stop (seconds)
    var silenceTimeout: TimeInterval = 60.0

    init(
        outputDir: String,
        meetingApp: String,
        entity: String,
        meetingTitle: String,
        attendees: [String] = [],
        sampleRate: Double = 16000,
        pids: [pid_t] = [],
        isBrowserBased: Bool = false
    ) throws {
        self.sampleRate = sampleRate
        self.meetingApp = meetingApp
        self.entity = entity
        self.meetingTitle = meetingTitle
        self.attendees = attendees
        self.startTime = Date()
        self.lastAudioActivity = Date()

        // Generate output filename (just timestamp — title added after user confirmation)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = dateFormatter.string(from: startTime)
        self.outputPath = "\(outputDir)/\(timestamp).wav"

        // Create output directory
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // Set up system audio capture FIRST — if this fails, don't create the WAV file
        let tapManager = AudioTapManager()
        let tapConfig = TapConfiguration(
            processes: pids,
            muteBehavior: .unmuted,
            isExclusive: !isBrowserBased, // non-exclusive for browser (all Chrome audio)
            isMono: true
        )

        try tapManager.setupAudioTap(with: tapConfig)
        self.tapManager = tapManager

        guard let deviceID = tapManager.getDeviceID() else {
            throw RecordingError.noAudioDevice
        }

        let systemHandler = SystemAudioHandler(
            onPacket: { [weak self] packet in
                guard let self = self else { return }
                self.lock.lock()
                self.systemBuffer.append(packet.data)
                self.lastAudioActivity = Date()
                self.lock.unlock()
            }
        )

        self.recorder = try AudioRecorder(
            deviceID: deviceID,
            outputHandler: systemHandler,
            convertToSampleRate: sampleRate,
            chunkDuration: 0.2
        )

        // Audio tap succeeded — now create the WAV file
        self.wavWriter = try WAVWriter(
            path: outputPath,
            sampleRate: UInt32(sampleRate),
            channels: 2,
            bitsPerSample: 16
        )

        // Set up mic capture
        self.micCapture = MicCapture { [weak self] buffer, _ in
            guard let self = self, let floatData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            var pcmData = Data(capacity: frameCount * 2)

            for i in 0..<frameCount {
                let sample = max(-1.0, min(1.0, floatData[0][i]))
                var int16 = Int16(sample * Float(Int16.max))
                pcmData.append(Data(bytes: &int16, count: 2))
            }

            self.lock.lock()
            self.micBuffer.append(pcmData)
            self.lastAudioActivity = Date()
            self.lock.unlock()
        }
    }

    func start() throws {
        guard !isRecording else { return }

        try recorder?.startRecording()
        try micCapture?.start(desiredSampleRate: sampleRate)

        // Interleave timer — combines system + mic into stereo WAV
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            self?.interleaveAndWrite()
            self?.checkSilence()
        }
        timer.resume()
        self.interleaveTimer = timer

        isRecording = true
        fputs("[session] Recording started: \(outputPath)\n", stderr)
    }

    func stop() -> RecordingResult {
        guard isRecording else {
            return RecordingResult(
                path: outputPath, duration: 0, meetingApp: meetingApp,
                entity: entity, meetingTitle: meetingTitle, attendees: attendees,
                sampleRate: sampleRate
            )
        }

        interleaveTimer?.cancel()
        recorder?.stopRecording()
        micCapture?.stop()

        // Flush remaining audio
        interleaveAndWrite()

        wavWriter?.finalize()
        isRecording = false

        let duration = Date().timeIntervalSince(startTime)
        fputs("[session] Recording stopped (\(Int(duration))s): \(outputPath)\n", stderr)

        // Clean up files from very short recordings (likely false triggers)
        if duration < 10 {
            fputs("[session] Recording too short (\(Int(duration))s) — deleting file\n", stderr)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        return RecordingResult(
            path: outputPath,
            duration: duration,
            meetingApp: meetingApp,
            entity: entity,
            meetingTitle: meetingTitle,
            attendees: attendees,
            sampleRate: sampleRate
        )
    }

    private func interleaveAndWrite() {
        lock.lock()
        let sysData = systemBuffer
        let micData = micBuffer
        systemBuffer = Data()
        micBuffer = Data()
        lock.unlock()

        let bytesPerSample = 2
        let sysFrames = sysData.count / bytesPerSample
        let micFrames = micData.count / bytesPerSample
        let frameCount = max(sysFrames, micFrames)

        guard frameCount > 0 else { return }

        var stereoData = Data(capacity: frameCount * bytesPerSample * 2)
        let silence = Data(repeating: 0, count: bytesPerSample)

        for i in 0..<frameCount {
            if i < sysFrames {
                let offset = i * bytesPerSample
                stereoData.append(sysData[offset..<offset + bytesPerSample])
            } else {
                stereoData.append(silence)
            }

            if i < micFrames {
                let offset = i * bytesPerSample
                stereoData.append(micData[offset..<offset + bytesPerSample])
            } else {
                stereoData.append(silence)
            }
        }

        wavWriter?.writeAudioData(stereoData)
    }

    private func checkSilence() {
        let silenceDuration = Date().timeIntervalSince(lastAudioActivity)
        if silenceDuration >= silenceTimeout {
            fputs("[session] Silence timeout reached (\(Int(silenceDuration))s)\n", stderr)
            DispatchQueue.main.async { [weak self] in
                self?.onSilenceTimeout?()
            }
        }
    }

    enum RecordingError: Error {
        case noAudioDevice
    }
}

/// Result returned when a recording session ends
struct RecordingResult {
    let path: String
    let duration: TimeInterval
    let meetingApp: String
    let entity: String
    let meetingTitle: String
    let attendees: [String]
    let sampleRate: Double

    var durationMinutes: Int { Int(duration / 60) }

    var metadataJSON: String {
        let dateFormatter = ISO8601DateFormatter()
        let date = dateFormatter.string(from: Date())
        return """
        {
          "file": "\(URL(fileURLWithPath: path).lastPathComponent)",
          "date": "\(date)",
          "duration_seconds": \(Int(duration)),
          "meeting_app": "\(meetingApp)",
          "calendar_event": "\(meetingTitle)",
          "attendees": \(attendees),
          "sample_rate": \(Int(sampleRate)),
          "channels": 2,
          "format": "wav",
          "entity": "\(entity)"
        }
        """
    }
}
