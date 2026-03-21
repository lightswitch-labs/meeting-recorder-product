import AVFoundation
import Foundation

/// Captures microphone audio using AVAudioEngine, resamples to the desired sample rate,
/// and delivers PCM buffers via a callback. Handles device changes mid-recording
/// (e.g., AirPods connecting) by restarting the audio engine.
final class MicCapture {
    private var engine = AVAudioEngine()
    private let onBuffer: (AVAudioPCMBuffer, AVAudioTime) -> Void
    private var converter: AVAudioConverter?
    private(set) var sampleRate: Double = 0
    private(set) var isRunning = false
    private var desiredSampleRate: Double = 16000
    private var deviceChangeObserver: NSObjectProtocol?

    init(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.onBuffer = onBuffer
    }

    func start(desiredSampleRate: Double = 16000) throws {
        self.desiredSampleRate = desiredSampleRate
        try startEngine()
        observeDeviceChanges()
    }

    func stop() {
        if let observer = deviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            deviceChangeObserver = nil
        }
        stopEngine()
    }

    // MARK: - Engine Lifecycle

    private func startEngine() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        sampleRate = desiredSampleRate

        fputs("[mic] Input device: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch\n", stderr)
        fputs("[mic] Resampling to: \(Int(desiredSampleRate))Hz\n", stderr)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: desiredSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicError.cannotCreateFormat
        }

        guard let audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicError.cannotCreateConverter
        }
        self.converter = audioConverter

        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            guard let self = self, let converter = self.converter else { return }

            let ratio = self.desiredSampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            var error: NSError?
            var hasData = true
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if hasData {
                    hasData = false
                    outStatus.pointee = .haveData
                    return buffer
                }
                outStatus.pointee = .noDataNow
                return nil
            }

            if error == nil && outputBuffer.frameLength > 0 {
                self.onBuffer(outputBuffer, time)
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        fputs("[mic] Recording started\n", stderr)
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        fputs("[mic] Recording stopped\n", stderr)
    }

    // MARK: - Device Change Handling

    private func observeDeviceChanges() {
        // AVAudioEngine posts this when the audio route changes
        // (e.g., AirPods connect, headphones plugged in, USB mic attached)
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            fputs("[mic] Audio device changed — restarting capture\n", stderr)
            self.handleDeviceChange()
        }
    }

    private func handleDeviceChange() {
        // Stop current engine
        stopEngine()

        // Small delay to let the new device settle
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            // Create a fresh engine (required after config change)
            self.engine = AVAudioEngine()
            do {
                try self.startEngine()
                fputs("[mic] Reconnected to new audio device\n", stderr)
            } catch {
                fputs("[mic] Failed to reconnect after device change: \(error)\n", stderr)
            }
        }
    }

    enum MicError: Error {
        case cannotCreateFormat
        case cannotCreateConverter
    }
}
