import AVFoundation

/// Captures microphone audio and delivers timestamped mono sample buffers,
/// ready to feed ``PitchTracker``.
///
/// ⚠️ Hardware-facing: this class opens the live input device and cannot run
/// in CI, so it stays a thin shell — all logic worth testing lives in
/// ``PitchTracker`` and downstream. The app target must carry the microphone
/// entitlement and an `NSMicrophoneUsageDescription`.
public final class MicEngine {

    /// One tap callback's worth of captured audio.
    public struct CapturedBuffer: Sendable {
        /// Mono samples (first channel of the hardware input format).
        public let samples: [Float]
        /// Capture time in host-clock seconds. Comparable across buffers
        /// from this engine; map into song time at the app level via
        /// ``SongClock`` and the calibrated latency offset.
        public let time: TimeInterval
        /// Sample rate of `samples`.
        public let sampleRate: Double
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<CapturedBuffer>.Continuation?

    /// Whether the input engine is currently capturing.
    public private(set) var isRunning = false

    /// Creates an idle engine.
    public init() {}

    deinit {
        stop()
    }

    /// Starts capturing and returns the stream of buffers. Buffer sizes are
    /// a request — Core Audio may deliver other sizes. The stream finishes
    /// when `stop()` is called; slow consumers only ever lag by a few
    /// buffers (older ones are dropped, and stale pitch is useless anyway).
    public func start(bufferSize: AVAudioFrameCount = 2048) throws -> AsyncStream<CapturedBuffer> {
        stop()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let (stream, continuation) = AsyncStream.makeStream(
            of: CapturedBuffer.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, when in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let time: TimeInterval
            if when.isHostTimeValid {
                time = AVAudioTime.seconds(forHostTime: when.hostTime)
            } else {
                time = Double(when.sampleTime) / format.sampleRate
            }
            continuation.yield(CapturedBuffer(samples: samples, time: time, sampleRate: format.sampleRate))
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        return stream
    }

    /// Stops capturing and finishes the stream.
    public func stop() {
        guard isRunning || continuation != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        isRunning = false
    }
}
