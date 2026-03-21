import Foundation

/// Writes raw PCM audio data to a WAV file, handling header creation and finalization.
final class WAVWriter {
    private let fileHandle: FileHandle
    private let filePath: String
    private var dataSize: UInt32 = 0
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16

    init(path: String, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) throws {
        self.filePath = path
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw WAVError.cannotOpenFile(path)
        }
        self.fileHandle = handle

        // Write placeholder header (44 bytes) — finalized on close
        let header = buildHeader(dataSize: 0)
        fileHandle.write(header)
    }

    func writeAudioData(_ data: Data) {
        fileHandle.write(data)
        dataSize += UInt32(data.count)
    }

    func finalize() {
        // Seek to beginning and rewrite header with correct data size
        fileHandle.seek(toFileOffset: 0)
        let header = buildHeader(dataSize: dataSize)
        fileHandle.write(header)
        fileHandle.closeFile()
    }

    private func buildHeader(dataSize: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        let fileSize = 36 + dataSize

        var header = Data(capacity: 44)

        // RIFF chunk
        header.append(contentsOf: "RIFF".utf8)
        header.appendLittleEndian(fileSize)
        header.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        header.appendLittleEndian(UInt32(16))       // sub-chunk size
        header.appendLittleEndian(UInt16(1))         // PCM format
        header.appendLittleEndian(channels)
        header.appendLittleEndian(sampleRate)
        header.appendLittleEndian(byteRate)
        header.appendLittleEndian(blockAlign)
        header.appendLittleEndian(bitsPerSample)

        // data sub-chunk
        header.append(contentsOf: "data".utf8)
        header.appendLittleEndian(dataSize)

        return header
    }

    enum WAVError: Error {
        case cannotOpenFile(String)
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 2))
    }
}
