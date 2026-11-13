// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFAudio

enum AppSoundCodec {
    static let maximumDuration = 29.99
    struct Info: Sendable {
        let duration: Double
        let sampleRate: Double
        let channels: UInt32
        let format: UInt32
    }
    static func inspect(_ data: Data, extension suffix: String) throws -> Info {
        guard !data.isEmpty, data.count <= AppSoundDirectory.maximumFile else {
            throw CustomizationFailure("Choose notification audio shorter than 30 seconds and smaller than 32 MB.")
        }
        return try temporary { folder in
            let url = folder.appendingPathComponent("sound").appendingPathExtension(suffix)
            try data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard file.length > 0, duration.isFinite, duration > 0, duration <= maximumDuration else {
                throw CustomizationFailure("Choose notification audio shorter than 30 seconds and smaller than 32 MB.")
            }
            return Info(duration: duration, sampleRate: file.processingFormat.sampleRate,
                        channels: file.processingFormat.channelCount, format: file.fileFormat.streamDescription.pointee.mFormatID)
        }
    }
    static func namedReplacement(_ imported: Data, suffix: String, targetSuffix: String) throws -> Data {
        _ = try inspect(imported, extension: suffix)
        guard AppSoundDirectory.extensions.contains(targetSuffix.lowercased()) else {
            throw CustomizationFailure("This audio format is not supported.")
        }
        if ["mp3", "flac", "aac"].contains(targetSuffix.lowercased()) {
            guard suffix.lowercased() == targetSuffix.lowercased() else {
                throw CustomizationFailure("This format cannot be converted. Import audio with the same format, sample rate and channel count.")
            }
            return imported
        }
        return try temporary { folder in
            let url = folder.appendingPathComponent("reference").appendingPathExtension(targetSuffix)
            var settings: [String: Any] = [AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 1]
            if targetSuffix.lowercased() == "m4a" {
                settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
                settings[AVEncoderBitRateKey] = 128000
            } else {
                settings[AVFormatIDKey] = kAudioFormatLinearPCM
                settings[AVLinearPCMBitDepthKey] = 16
                settings[AVLinearPCMIsFloatKey] = false
                settings[AVLinearPCMIsBigEndianKey] = ["aif", "aiff"].contains(targetSuffix.lowercased())
            }
            try autoreleasepool {
                let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let silence = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 4410) else {
                    throw CustomizationFailure("This audio format is not supported.")
                }
                silence.frameLength = 4410
                if let channels = silence.floatChannelData { memset(channels[0], 0, Int(silence.frameLength) * MemoryLayout<Float>.size) }
                try writer.write(from: silence)
            }
            return try replacement(imported, suffix: suffix, original: Data(contentsOf: url), targetSuffix: targetSuffix)
        }
    }
    /// Retain the target container type, sample rate and channel count. Changing
    /// only a filename extension would leave callers with an invalid resource.
    static func replacement(_ imported: Data, suffix: String, original: Data, targetSuffix: String) throws -> Data {
        _ = try inspect(imported, extension: suffix)
        _ = try inspect(original, extension: targetSuffix)
        return try temporary { folder in
            let sourceURL = folder.appendingPathComponent("source").appendingPathExtension(suffix)
            let referenceURL = folder.appendingPathComponent("reference").appendingPathExtension(targetSuffix)
            let outputURL = folder.appendingPathComponent("output").appendingPathExtension(targetSuffix)
            try imported.write(to: sourceURL); try original.write(to: referenceURL)
            let source = try AVAudioFile(forReading: sourceURL)
            let reference = try AVAudioFile(forReading: referenceURL)
            let info = reference.fileFormat.streamDescription.pointee
            // AVAudioFile cannot encode MP3/FLAC/ADTS on every OS. Preserve a
            // matching imported stream rather than pretending conversion worked.
            if ["mp3", "flac", "aac"].contains(targetSuffix.lowercased()) {
                let input = source.fileFormat.streamDescription.pointee
                guard input.mFormatID == info.mFormatID, input.mSampleRate == info.mSampleRate,
                      input.mChannelsPerFrame == info.mChannelsPerFrame,
                      suffix.lowercased() == targetSuffix.lowercased() else {
                    throw CustomizationFailure("This format cannot be converted. Import audio with the same format, sample rate and channel count.")
                }
                return imported
            }
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: reference.processingFormat.sampleRate,
                                            channels: reference.processingFormat.channelCount, interleaved: false),
                  let converter = AVAudioConverter(from: source.processingFormat, to: format),
                  let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw CustomizationFailure("This audio format is not supported.")
            }
            try autoreleasepool {
                // Close the output before reading its finalized header below.
                let writer = try AVAudioFile(forWriting: outputURL, settings: reference.fileFormat.settings,
                                             commonFormat: .pcmFormatFloat32, interleaved: false)
                var inputError: Error?
                var total: AVAudioFramePosition = 0
                while true {
                    try Task.checkCancellation()
                    var conversionError: NSError?
                    let status = converter.convert(to: output, error: &conversionError) { requested, result in
                        do {
                            let remaining = source.length - source.framePosition
                            guard remaining > 0 else { result.pointee = .endOfStream; return nil }
                            let count = AVAudioFrameCount(min(AVAudioFramePosition(min(requested, input.frameCapacity)), remaining))
                            try source.read(into: input, frameCount: count)
                            result.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                            return input.frameLength == 0 ? nil : input
                        } catch { inputError = error; result.pointee = .endOfStream; return nil }
                    }
                    if let inputError { throw inputError }
                    if let conversionError { throw conversionError }
                    if output.frameLength > 0 { try writer.write(from: output); total += AVAudioFramePosition(output.frameLength) }
                    guard Double(total) / format.sampleRate <= maximumDuration + 0.1 else {
                        throw CustomizationFailure("Choose notification audio shorter than 30 seconds and smaller than 32 MB.")
                    }
                    if status == .endOfStream { break }
                    guard status != .error, output.frameLength > 0 else {
                        throw CustomizationFailure("This audio format is not supported.")
                    }
                }
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= AppSoundDirectory.maximumFile else {
                throw CustomizationFailure("Choose notification audio shorter than 30 seconds and smaller than 32 MB.")
            }
            let result = try Data(contentsOf: outputURL)
            let outputInfo = try inspect(result, extension: targetSuffix)
            guard outputInfo.format == info.mFormatID, outputInfo.sampleRate == info.mSampleRate,
                  outputInfo.channels == info.mChannelsPerFrame else { throw CustomizationFailure("This audio format is not supported.") }
            return result
        }
    }
    private static func temporary<T>(_ body: (URL) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GX-Audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }
}
