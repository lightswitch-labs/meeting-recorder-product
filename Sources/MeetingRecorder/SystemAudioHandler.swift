import AudioTeeCore
import Foundation

/// Receives system audio packets from AudioTeeCore and writes them to the left channel
/// of a stereo WAV file. Mic audio is written to the right channel by MicCapture.
final class SystemAudioHandler: AudioOutputHandler {
    private let onPacket: (AudioPacket) -> Void
    private let onStart: () -> Void
    private let onStop: () -> Void
    private var metadata: AudioStreamMetadata?

    init(
        onPacket: @escaping (AudioPacket) -> Void,
        onStart: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {}
    ) {
        self.onPacket = onPacket
        self.onStart = onStart
        self.onStop = onStop
    }

    func handleAudioPacket(_ packet: AudioPacket) {
        onPacket(packet)
    }

    func handleMetadata(_ metadata: AudioStreamMetadata) {
        self.metadata = metadata
        let rate = Int(metadata.sampleRate)
        let bits = metadata.bitsPerChannel
        let float = metadata.isFloat ? "float" : "int"
        fputs("[system-audio] Stream: \(rate)Hz, \(bits)-bit \(float), \(metadata.channelsPerFrame)ch\n", stderr)
    }

    func handleStreamStart() {
        fputs("[system-audio] Recording started\n", stderr)
        onStart()
    }

    func handleStreamStop() {
        fputs("[system-audio] Recording stopped\n", stderr)
        onStop()
    }
}
