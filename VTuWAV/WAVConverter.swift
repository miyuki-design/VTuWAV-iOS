import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

enum WAVConversionError: LocalizedError {
    case noAudio
    case unsupportedAudio
    case cannotRead
    case emptyAudio
    case fileTooLarge
    case protectedOrUnsupported

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return "音声トラックが見つかりませんでした。"
        case .unsupportedAudio:
            return "この音声形式はWAVへの変換に対応していません。"
        case .cannotRead:
            return "音声データを読み取れませんでした。"
        case .emptyAudio:
            return "音声データが空でした。"
        case .fileTooLarge:
            return "WAVの4GB上限を超えるため書き出せません。"
        case .protectedOrUnsupported:
            return "変換できませんでした。DRMで保護された配信曲や、非対応のファイルは読み込めません。"
        }
    }
}

enum FileStaging {
    /// File Provider / iCloud URL permissions are used only while making our own copy.
    static func copyToSandbox(from externalURL: URL) throws -> URL {
        let granted = externalURL.startAccessingSecurityScopedResource()
        defer { if granted { externalURL.stopAccessingSecurityScopedResource() } }

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(externalURL.pathExtension.isEmpty ? "tmp" : externalURL.pathExtension)
        try FileManager.default.copyItem(at: externalURL, to: target)
        return target
    }
}

enum WAVConverter {
    /// Converts a local, unprotected audio track to interleaved, little-endian PCM16 WAV.
    /// The original sample rate and channel count are retained; this is not an upsampler.
    static func convert(_ input: URL) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WAVConversionError.noAudio
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WAVConversionError.protectedOrUnsupported
        }

        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(trackOutput) else { throw WAVConversionError.unsupportedAudio }
        reader.add(trackOutput)
        guard reader.startReading() else { throw WAVConversionError.protectedOrUnsupported }

        let outputName = input.deletingPathExtension().lastPathComponent + "_WAV_" + String(UUID().uuidString.prefix(6)) + ".wav"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(outputName)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        do {
            // Save a placeholder header. We read the *decoded* PCM format from the sample,
            // so the WAV header can't accidentally describe the compressed source format.
            try output.write(contentsOf: Data(repeating: 0, count: 44))
            var format: AudioStreamBasicDescription?
            var audioBytes: UInt64 = 0

            while let sample = trackOutput.copyNextSampleBuffer() {
                defer { CMSampleBufferInvalidate(sample) }
                if format == nil {
                    guard let description = CMSampleBufferGetFormatDescription(sample),
                          let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
                        throw WAVConversionError.unsupportedAudio
                    }
                    let asbd = asbdPointer.pointee
                    guard asbd.mFormatID == kAudioFormatLinearPCM,
                          asbd.mBitsPerChannel == 16,
                          asbd.mSampleRate > 0,
                          asbd.mChannelsPerFrame > 0,
                          asbd.mChannelsPerFrame <= 8,
                          (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 else {
                        throw WAVConversionError.unsupportedAudio
                    }
                    format = asbd
                }
                guard let block = CMSampleBufferGetDataBuffer(sample) else {
                    throw WAVConversionError.cannotRead
                }
                let byteCount = CMBlockBufferGetDataLength(block)
                if byteCount == 0 { continue }
                if audioBytes + UInt64(byteCount) > UInt64(UInt32.max) - 36 {
                    throw WAVConversionError.fileTooLarge
                }
                var bytes = Data(count: byteCount)
                let status = bytes.withUnsafeMutableBytes { rawBuffer in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                               destination: rawBuffer.baseAddress!)
                }
                guard status == noErr else { throw WAVConversionError.cannotRead }
                try output.write(contentsOf: bytes)
                audioBytes += UInt64(byteCount)
            }

            guard reader.status == .completed else { throw WAVConversionError.protectedOrUnsupported }
            guard let format, audioBytes > 0 else { throw WAVConversionError.emptyAudio }
            let wavHeader = try makeWAVHeader(
                sampleRate: Int(format.mSampleRate.rounded()),
                channels: Int(format.mChannelsPerFrame),
                dataSize: UInt32(audioBytes)
            )
            try output.seek(toOffset: 0)
            try output.write(contentsOf: wavHeader)
            return outputURL
        } catch {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func makeWAVHeader(sampleRate: Int, channels: Int,
                                      dataSize: UInt32) throws -> Data {
        guard sampleRate > 0, sampleRate <= 384_000, channels > 0, channels <= 8 else {
            throw WAVConversionError.unsupportedAudio
        }
        let bytesPerSample = 2 // signed 16-bit PCM
        let blockAlign = UInt16(channels * bytesPerSample)
        let byteRate = UInt32(sampleRate * channels * bytesPerSample)
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE(dataSize + 36)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE(UInt32(16)) // length of PCM format chunk
        header.appendLE(UInt16(1))  // format ID = integer PCM
        header.appendLE(UInt16(channels))
        header.appendLE(UInt32(sampleRate))
        header.appendLE(byteRate)
        header.appendLE(blockAlign)
        header.appendLE(UInt16(16))
        header.append(contentsOf: "data".utf8)
        header.appendLE(dataSize)
        return header
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ number: T) {
        var value = number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
