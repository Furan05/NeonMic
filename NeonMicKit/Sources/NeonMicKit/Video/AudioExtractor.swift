import AVFoundation

/// Errors thrown by ``AudioExtractor``.
public enum AudioExtractionError: Error, Equatable {
    /// AVFoundation cannot open the file as a media asset.
    case cannotRead(String)
    /// The asset has no audio track to extract.
    case noAudioTrack
    /// Decoding or encoding failed mid-stream.
    case extractionFailed(String)
}

/// Seam over ``AudioExtractor`` so ``VideoDownloaderService`` tests can stub
/// extraction out.
public protocol AudioExtracting: Sendable {
    /// Extracts the audio track of `videoURL` into `outputURL` and returns
    /// the written file.
    func extractAudio(from videoURL: URL, to outputURL: URL) async throws -> URL
}

/// Re-encodes a video's audio track as a standalone AAC `.m4a` using only
/// AVFoundation (no ffmpeg dependency).
///
/// Why AAC and not MP3: macOS ships no MP3 *encoder* — AVFoundation and
/// AudioToolbox decode MP3 but can only encode AAC, ALAC, and PCM. The
/// configured default (AAC 320 kbps, 44.1 kHz stereo) is the transparent
/// native equivalent of "MP3 320 kbps", and UltraStar charts reference
/// `.m4a` in `#AUDIO` just as happily as `.mp3`.
public struct AudioExtractor: AudioExtracting {

    /// Output encoding parameters.
    public struct Configuration: Sendable {
        /// AAC bit rate in bits per second (320 kbps default, the Apple
        /// encoder's ceiling for 44.1 kHz stereo).
        public var bitRate = 320_000
        /// Output sample rate in Hz.
        public var sampleRate = 44_100.0
        /// Output channel count.
        public var channelCount = 2

        /// Creates the default configuration.
        public init() {}
    }

    private let configuration: Configuration

    /// Creates an extractor.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func extractAudio(from videoURL: URL, to outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioExtractionError.cannotRead(String(describing: error))
        }
        guard let track = tracks.first else { throw AudioExtractionError.noAudioTrack }

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            throw AudioExtractionError.cannotRead(String(describing: error))
        }

        // Decode to canonical interleaved PCM at the output rate, so the
        // writer's AAC encoder never has to guess about conversions.
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: configuration.sampleRate,
            AVNumberOfChannelsKey: configuration.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: configuration.sampleRate,
            AVNumberOfChannelsKey: configuration.channelCount,
            AVEncoderBitRateKey: configuration.bitRate,
        ])
        guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else {
            throw AudioExtractionError.extractionFailed("incompatible track settings")
        }
        reader.add(readerOutput)
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioExtractionError.extractionFailed(String(describing: reader.error))
        }
        guard writer.startWriting() else {
            throw AudioExtractionError.extractionFailed(String(describing: writer.error))
        }
        writer.startSession(atSourceTime: .zero)

        // The AVFoundation objects are not Sendable, but the pump closure is
        // the sole user past this point and runs on one serial queue.
        let pump = Pump(reader: reader, writer: writer,
                        readerOutput: readerOutput, writerInput: writerInput)
        let queue = DispatchQueue(label: "com.francoisdubois.neonmic.audio-extract")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                pump.drain(resuming: continuation)
            }
        }
        return outputURL
    }

    /// Moves decoded samples into the encoder until the source runs dry,
    /// then finalizes the output file. Confined to the extractor's serial
    /// queue, hence the unchecked Sendable.
    private final class Pump: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let readerOutput: AVAssetReaderTrackOutput
        let writerInput: AVAssetWriterInput

        init(reader: AVAssetReader, writer: AVAssetWriter,
             readerOutput: AVAssetReaderTrackOutput, writerInput: AVAssetWriterInput) {
            self.reader = reader
            self.writer = writer
            self.readerOutput = readerOutput
            self.writerInput = writerInput
        }

        func drain(resuming continuation: CheckedContinuation<Void, Error>) {
            while writerInput.isReadyForMoreMediaData {
                if let sample = readerOutput.copyNextSampleBuffer() {
                    writerInput.append(sample)
                } else {
                    writerInput.markAsFinished()
                    if reader.status == .failed {
                        reader.cancelReading()
                        writer.cancelWriting()
                        continuation.resume(throwing: AudioExtractionError.extractionFailed(
                            String(describing: reader.error)))
                    } else {
                        writer.finishWriting {
                            if self.writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: AudioExtractionError.extractionFailed(
                                    String(describing: self.writer.error)))
                            }
                        }
                    }
                    return
                }
            }
        }
    }
}
