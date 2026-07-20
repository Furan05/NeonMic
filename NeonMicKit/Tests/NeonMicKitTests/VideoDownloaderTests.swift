import XCTest
import AVFoundation
@testable import NeonMicKit

/// Video download pipeline tests. Everything runs offline: transports are
/// mocked (or fed `file://` URLs), yt-dlp is exercised only through its pure
/// argument/progress helpers, and the AVFoundation extraction round-trip
/// synthesizes its own tiny MP4 fixture.
final class VideoDownloaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("neonmic-video-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - yt-dlp helpers (pure)

    func testYtDlpProgressLineParsing() {
        XCTAssertEqual(YtDlpVideoFetcher.parseProgressLine("[download]  42.3% of 12.34MiB at 1.2MiB/s"), 0.423)
        XCTAssertEqual(YtDlpVideoFetcher.parseProgressLine("[download] 100% of 12.34MiB in 00:05"), 1.0)
        XCTAssertEqual(YtDlpVideoFetcher.parseProgressLine("[download]   0.0% of ~5MiB"), 0.0)
        XCTAssertNil(YtDlpVideoFetcher.parseProgressLine("[download] Destination: video.mp4"))
        XCTAssertNil(YtDlpVideoFetcher.parseProgressLine("[youtube] dQw4w9WgXcQ: Downloading webpage"))
        XCTAssertNil(YtDlpVideoFetcher.parseProgressLine(""))
    }

    func testYtDlpArgumentsRequestMp4CappedAt1080p() throws {
        let source = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let args = YtDlpVideoFetcher.arguments(for: source, outputTemplate: "/tmp/Song.%(ext)s")

        let format = try XCTUnwrap(args.firstIndex(of: "-f").map { args[$0 + 1] })
        XCTAssertTrue(format.contains("[ext=mp4][height<=1080]"), "must prefer MP4 capped at 1080p")
        XCTAssertTrue(args.contains("--newline"), "progress must be line-parseable")
        XCTAssertTrue(args.contains("--no-cache-dir"), "no writes outside the sandbox")
        XCTAssertEqual(args.suffix(2), ["--", source.absoluteString], "URL must be inert to option parsing")
        let template = try XCTUnwrap(args.firstIndex(of: "-o").map { args[$0 + 1] })
        XCTAssertEqual(template, "/tmp/Song.%(ext)s")
    }

    func testYtDlpLocateExecutableReturnsNilWhenAbsent() {
        XCTAssertNil(YtDlpVideoFetcher.locateExecutable(searchPaths: ["/nonexistent/yt-dlp"]))
    }

    func testFetchWithoutYtDlpThrowsNotFound() async {
        let fetcher = YtDlpVideoFetcher(executableURL: nil)
        let source = URL(string: "https://www.youtube.com/watch?v=x")!
        do {
            _ = try await fetcher.fetchVideo(
                from: source, into: tempDir, baseName: "x", reporter: VideoFetchReporter())
            XCTFail("expected ytDlpNotFound")
        } catch {
            XCTAssertEqual(error as? VideoDownloadError, .ytDlpNotFound)
        }
    }

    // MARK: - Service routing & naming (pure)

    func testDirectMediaURLRouting() {
        XCTAssertTrue(VideoDownloaderService.isDirectMediaURL(URL(string: "https://cdn.example.com/a.mp4")!))
        XCTAssertTrue(VideoDownloaderService.isDirectMediaURL(URL(string: "https://cdn.example.com/a.MOV")!))
        XCTAssertTrue(VideoDownloaderService.isDirectMediaURL(URL(fileURLWithPath: "/tmp/a.bin")))
        XCTAssertFalse(VideoDownloaderService.isDirectMediaURL(URL(string: "https://www.youtube.com/watch?v=x")!))
        XCTAssertFalse(VideoDownloaderService.isDirectMediaURL(URL(string: "https://youtu.be/x")!))
    }

    func testSanitizedBaseName() {
        XCTAssertEqual(VideoDownloaderService.sanitizedBaseName(from: "AC/DC: Back In Black"),
                       "AC-DC- Back In Black")
        XCTAssertEqual(VideoDownloaderService.sanitizedBaseName(from: "Plain Name"), "Plain Name")
    }

    // MARK: - Queue behavior (mocked transport)

    func testDownloadsRunSequentiallyInFIFOOrder() async throws {
        let fetcher = MockVideoFetcher()
        let notifier = MockNotifier()
        let service = VideoDownloaderService(
            directFetcher: fetcher, siteFetcher: fetcher,
            audioExtractor: MockAudioExtractor(), notifier: notifier)

        async let first = service.downloadVideo(
            from: "https://cdn.example.com/a.mp4", songName: "Artist - A",
            into: tempDir, extractingAudio: false)
        // The queue keys on enqueue order; make sure A is in before B.
        await eventually { service.task(for: "Artist - A") != nil }
        async let second = service.downloadVideo(
            from: "https://cdn.example.com/b.mp4", songName: "Artist - B",
            into: tempDir, extractingAudio: false)

        let paths = try await (a: first, b: second)
        XCTAssertEqual(paths.a.videoURL.lastPathComponent, "Artist - A.mp4")
        XCTAssertEqual(paths.b.videoURL.lastPathComponent, "Artist - B.mp4")
        XCTAssertNil(paths.a.extractedAudioURL)
        XCTAssertEqual(fetcher.events, ["start:Artist - A", "end:Artist - A",
                                        "start:Artist - B", "end:Artist - B"],
                       "downloads must not interleave")
        XCTAssertEqual(notifier.completed, ["Artist - A", "Artist - B"])
        XCTAssertEqual(service.task(for: "Artist - A")?.state, .completed)
        XCTAssertFalse(service.isDownloading(songName: "Artist - A"))
    }

    func testProgressStreamAndProgressObjectAdvance() async throws {
        let fetcher = MockVideoFetcher()
        let service = VideoDownloaderService(
            directFetcher: fetcher, siteFetcher: fetcher, audioExtractor: MockAudioExtractor())

        async let result = service.downloadVideo(
            from: "https://cdn.example.com/a.mp4", songName: "Artist - A",
            into: tempDir, extractingAudio: false)
        await eventually { service.task(for: "Artist - A") != nil }
        let task = try XCTUnwrap(service.task(for: "Artist - A"))

        var fractions: [Double] = []
        var finalState: VideoDownloadState?
        for await update in task.updates {
            fractions.append(update.fractionCompleted)
            finalState = update.state
        }
        _ = try await result

        XCTAssertEqual(finalState, .completed)
        XCTAssertEqual(fractions.last, 1.0)
        XCTAssertEqual(fractions, fractions.sorted(), "progress must be monotonic")
        XCTAssertEqual(task.progress.completedUnitCount, 100)
    }

    func testCancelQueuedDownloadFlipsImmediatelyAndThrows() async throws {
        let fetcher = MockVideoFetcher()
        fetcher.holdNext = 1 // A blocks until released, keeping B queued
        let notifier = MockNotifier()
        let service = VideoDownloaderService(
            directFetcher: fetcher, siteFetcher: fetcher,
            audioExtractor: MockAudioExtractor(), notifier: notifier)

        async let first = service.downloadVideo(
            from: "https://cdn.example.com/a.mp4", songName: "Artist - A",
            into: tempDir, extractingAudio: false)
        await eventually { fetcher.events.contains("start:Artist - A") }
        async let second = service.downloadVideo(
            from: "https://cdn.example.com/b.mp4", songName: "Artist - B",
            into: tempDir, extractingAudio: false)
        await eventually { service.task(for: "Artist - B")?.state == .pending }

        service.cancelDownload(for: "Artist - B")
        XCTAssertEqual(service.task(for: "Artist - B")?.state, .cancelled,
                       "a queued download cancels without waiting for the head of the queue")
        fetcher.releaseAll()

        _ = try await first
        do {
            _ = try await second
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(fetcher.events.contains("start:Artist - B"), "cancelled work must never start")
        XCTAssertEqual(notifier.failed, [], "cancellation is not a failure")
    }

    func testCancelRunningDownloadEndsCancelled() async throws {
        let fetcher = MockVideoFetcher()
        fetcher.holdNext = 1
        let service = VideoDownloaderService(
            directFetcher: fetcher, siteFetcher: fetcher, audioExtractor: MockAudioExtractor())

        async let result = service.downloadVideo(
            from: "https://cdn.example.com/a.mp4", songName: "Artist - A",
            into: tempDir, extractingAudio: false)
        await eventually { fetcher.events.contains("start:Artist - A") }

        service.cancelDownload(for: "Artist - A")
        fetcher.releaseAll() // lets the mock observe the cancellation

        do {
            _ = try await result
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(service.task(for: "Artist - A")?.state, .cancelled)
    }

    func testSecondDownloadForSameSongThrowsAlreadyDownloading() async throws {
        let fetcher = MockVideoFetcher()
        fetcher.holdNext = 1
        let service = VideoDownloaderService(
            directFetcher: fetcher, siteFetcher: fetcher, audioExtractor: MockAudioExtractor())

        async let first = service.downloadVideo(
            from: "https://cdn.example.com/a.mp4", songName: "Artist - A",
            into: tempDir, extractingAudio: false)
        await eventually { service.isDownloading(songName: "Artist - A") }

        do {
            _ = try await service.downloadVideo(
                from: "https://cdn.example.com/a.mp4", songName: "Artist - A",
                into: tempDir, extractingAudio: false)
            XCTFail("expected alreadyDownloading")
        } catch {
            XCTAssertEqual(error as? VideoDownloadError, .alreadyDownloading(songName: "Artist - A"))
        }
        fetcher.releaseAll()
        _ = try await first
    }

    func testInvalidURLThrows() async {
        let service = VideoDownloaderService(
            directFetcher: MockVideoFetcher(), siteFetcher: MockVideoFetcher(),
            audioExtractor: MockAudioExtractor())
        do {
            _ = try await service.downloadVideo(
                from: "not a url", songName: "X", into: tempDir)
            XCTFail("expected invalidURL")
        } catch {
            XCTAssertEqual(error as? VideoDownloadError, .invalidURL("not a url"))
        }
    }

    func testConvenienceOverloadNeedsDestinationRoot() async {
        let service = VideoDownloaderService(
            directFetcher: MockVideoFetcher(), siteFetcher: MockVideoFetcher(),
            audioExtractor: MockAudioExtractor())
        do {
            _ = try await service.downloadVideo(from: "https://cdn.example.com/a.mp4", songName: "X")
            XCTFail("expected noDestinationConfigured")
        } catch {
            XCTAssertEqual(error as? VideoDownloadError, .noDestinationConfigured)
        }
    }

    func testExtractingAudioReportsPhaseAndReturnsAudioPath() async throws {
        let service = VideoDownloaderService(
            directFetcher: MockVideoFetcher(), siteFetcher: MockVideoFetcher(),
            audioExtractor: MockAudioExtractor())

        let paths = try await service.downloadVideo(
            from: "https://cdn.example.com/a.mp4", songName: "Artist - A",
            into: tempDir, extractingAudio: true)
        XCTAssertEqual(paths.extractedAudioURL?.lastPathComponent, "Artist - A.m4a")
    }

    // MARK: - URLSession transport (file:// — no network)

    func testURLSessionFetcherDownloadsDirectURL() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let sourceURL = tempDir.appendingPathComponent("source-clip.mp4")
        try payload.write(to: sourceURL)
        let destinationDir = tempDir.appendingPathComponent("song", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let progressLog = ProgressLog()
        let result = try await URLSessionVideoFetcher().fetchVideo(
            from: sourceURL,
            into: destinationDir,
            baseName: "Artist - Song",
            reporter: VideoFetchReporter(onProgress: { progressLog.append($0) }))

        XCTAssertEqual(result.lastPathComponent, "Artist - Song.mp4")
        XCTAssertEqual(try Data(contentsOf: result), payload, "bytes must round-trip exactly")
        XCTAssertEqual(progressLog.snapshots.last?.fractionCompleted, 1.0)
        XCTAssertEqual(progressLog.snapshots.last?.bytesReceived, Int64(payload.count))
    }

    // MARK: - LibraryScanner

    func testScannerParsesFoldersAndPrefersMp4OverMov() throws {
        let folder = try makeSongFolder(
            named: "The Neon Signals - Test Tune",
            chart: minimalChart(title: "Test Tune", artist: "The Neon Signals"))
        try Data().write(to: folder.appendingPathComponent("clip.mov"))
        try Data().write(to: folder.appendingPathComponent("clip.mp4"))

        let report = LibraryScanner().scan(libraryRoot: tempDir)

        XCTAssertEqual(report.failures.count, 0)
        let song = try XCTUnwrap(report.entries.first?.song)
        XCTAssertEqual(song.videoFileName, "clip.mp4", "MP4 must win over MOV")
        // Directory enumeration resolves /var to /private/var; normalize both
        // sides before comparing.
        XCTAssertEqual(song.libraryFolderURL?.resolvingSymlinksInPath(),
                       folder.resolvingSymlinksInPath())
        XCTAssertTrue(song.hasVideo)
        XCTAssertEqual(song.videoPath?.resolvingSymlinksInPath(),
                       folder.appendingPathComponent("clip.mp4").resolvingSymlinksInPath())
    }

    func testScannerKeepsExistingVideoHeaderAndReplacesUsdbTag() throws {
        // Folder 1: header names a real file — kept, even with another video around.
        let kept = try makeSongFolder(
            named: "A - Named",
            chart: minimalChart(title: "Named", artist: "A", extraHeaders: ["#VIDEO:official.mov"]))
        try Data().write(to: kept.appendingPathComponent("official.mov"))
        try Data().write(to: kept.appendingPathComponent("other.mp4"))

        // Folder 2: usdb-style tag is a download hint, not a file — replaced
        // by the video actually on disk.
        let tagged = try makeSongFolder(
            named: "B - Tagged",
            chart: minimalChart(title: "Tagged", artist: "B", extraHeaders: ["#VIDEO:v=dQw4w9WgXcQ"]))
        try Data().write(to: tagged.appendingPathComponent("downloaded.mp4"))

        let report = LibraryScanner().scan(libraryRoot: tempDir)
        let songs = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.song.title, $0.song) })

        XCTAssertEqual(songs["Named"]?.videoFileName, "official.mov")
        XCTAssertEqual(songs["Tagged"]?.videoFileName, "downloaded.mp4")
    }

    func testScannerIgnoresChartlessFoldersAndReportsBrokenCharts() throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("_INBOX - drop your first song here"),
            withIntermediateDirectories: true)
        _ = try makeSongFolder(named: "Broken - Chart", chart: "#TITLE:Broken\nE\n")

        let report = LibraryScanner().scan(libraryRoot: tempDir)

        XCTAssertEqual(report.entries.count, 0)
        XCTAssertEqual(report.failures.count, 1, "a chartless folder is ignored, a broken chart is reported")
        XCTAssertEqual(report.failures.first?.folderURL.lastPathComponent, "Broken - Chart")
    }

    // MARK: - Song video extension

    func testSongVideoSourceFromVideoURLHeaderAndUsdbTag() {
        var song = Song(title: "T", artist: "A", bpm: 120,
                        rawHeaders: ["VIDEOURL": "https://example.com/clip.mp4"])
        XCTAssertEqual(song.videoSourceURL?.absoluteString, "https://example.com/clip.mp4")

        song = Song(title: "T", artist: "A", bpm: 120, videoFileName: "v=dQw4w9WgXcQ,co=cover.jpg")
        XCTAssertEqual(song.videoSourceURL?.absoluteString,
                       "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

        song = Song(title: "T", artist: "A", bpm: 120, videoFileName: "clip.mp4")
        XCTAssertNil(song.videoSourceURL, "a local file name is not a download source")
    }

    func testSongVideoPropertiesWithoutLibraryContext() {
        let song = Song(title: "T", artist: "A", bpm: 120, videoFileName: "clip.mp4")
        XCTAssertNil(song.videoPath, "no library folder, nowhere to resolve the file")
        XCTAssertFalse(song.hasVideo)
        XCTAssertFalse(song.isVideoDownloading)
        XCTAssertEqual(song.librarySongName, "A - T")
    }

    func testSongDownloadVideoThrowsWithoutSourceOrFolder() async {
        let service = VideoDownloaderService(
            directFetcher: MockVideoFetcher(), siteFetcher: MockVideoFetcher(),
            audioExtractor: MockAudioExtractor())

        let noSource = Song(title: "T", artist: "A", bpm: 120, libraryFolderURL: tempDir)
        do {
            _ = try await noSource.downloadVideo(using: service)
            XCTFail("expected noVideoSource")
        } catch {
            XCTAssertEqual(error as? VideoDownloadError, .noVideoSource)
        }

        let noFolder = Song(title: "T", artist: "A", bpm: 120,
                            rawHeaders: ["VIDEOURL": "https://example.com/clip.mp4"])
        do {
            _ = try await noFolder.downloadVideo(using: service)
            XCTFail("expected noLibraryFolder")
        } catch {
            XCTAssertEqual(error as? VideoDownloadError, .noLibraryFolder)
        }
    }

    func testSongDownloadVideoSkipsExtractionWhenChartHasAudio() async throws {
        let service = VideoDownloaderService(
            directFetcher: MockVideoFetcher(), siteFetcher: MockVideoFetcher(),
            audioExtractor: MockAudioExtractor())
        let song = Song(title: "T", artist: "A", bpm: 120,
                        audioFileName: "owned.mp3",
                        rawHeaders: ["VIDEOURL": "https://example.com/clip.mp4"],
                        libraryFolderURL: tempDir)

        let paths = try await song.downloadVideo(using: service)

        XCTAssertNil(paths.extractedAudioURL, "an owned audio file must never be shadowed")
        XCTAssertEqual(paths.videoURL.lastPathComponent, "A - T.mp4")
    }

    // MARK: - AudioExtractor (AVFoundation round-trip)

    func testExtractorProducesPlayableAacM4a() async throws {
        let videoURL = tempDir.appendingPathComponent("fixture.mp4")
        try Self.writeVideoContainerWithSineAudio(to: videoURL, seconds: 1.0)

        let outputURL = tempDir.appendingPathComponent("extracted.m4a")
        let result = try await AudioExtractor().extractAudio(from: videoURL, to: outputURL)

        let audioFile = try AVAudioFile(forReading: result)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        XCTAssertEqual(duration, 1.0, accuracy: 0.15, "AAC priming may shift edges slightly")
        XCTAssertEqual(audioFile.processingFormat.sampleRate, 44_100)
        XCTAssertEqual(audioFile.processingFormat.channelCount, 2)
        let formatID = audioFile.fileFormat.settings[AVFormatIDKey] as? UInt32
        XCTAssertEqual(formatID, kAudioFormatMPEG4AAC, "output must be AAC — macOS has no MP3 encoder")
    }

    func testExtractorRejectsNonMediaFile() async throws {
        let garbage = tempDir.appendingPathComponent("garbage.mp4")
        try Data("definitely not a video".utf8).write(to: garbage)

        do {
            _ = try await AudioExtractor().extractAudio(
                from: garbage, to: tempDir.appendingPathComponent("out.m4a"))
            XCTFail("expected an extraction error")
        } catch let error as AudioExtractionError {
            switch error {
            case .cannotRead, .noAudioTrack:
                break
            case .extractionFailed(let message):
                XCTFail("unexpected mid-stream failure: \(message)")
            }
        }
    }

    // MARK: - Error classification (pure)

    func testYtDlpStderrClassifiesToSpecificCases() {
        func classify(_ stderr: String) -> VideoDownloadError {
            VideoDownloadError.fromYtDlp(exitCode: 1, message: stderr)
        }
        XCTAssertEqual(classify("ERROR: Private video. Sign in if you've been granted access"), .privateVideo)
        XCTAssertEqual(classify("ERROR: Video unavailable. This video is no longer available"), .videoUnavailable)
        XCTAssertEqual(classify("ERROR: This video is DRM protected"), .drmProtected)
        XCTAssertEqual(classify("ERROR: The uploader has not made this video available in your country"), .regionRestricted)
        XCTAssertEqual(classify("ERROR: You have requested merging of multiple formats but ffmpeg is not installed"), .ffmpegRequired)
        XCTAssertEqual(classify("ERROR: Unable to download webpage: <urlopen error [Errno 8] getaddrinfo failed>"), .networkUnavailable)
    }

    func testYtDlpStderrFallsBackToYtDlpFailed() {
        let error = VideoDownloadError.fromYtDlp(exitCode: 2, message: "ERROR: something weird happened")
        XCTAssertEqual(error, .ytDlpFailed(exitCode: 2, message: "ERROR: something weird happened"))
    }

    func testClassifyMapsSystemErrors() {
        XCTAssertEqual(
            VideoDownloadError.classify(URLError(.notConnectedToInternet)), .networkUnavailable)
        XCTAssertEqual(
            VideoDownloadError.classify(URLError(.timedOut)), .networkUnavailable)
        XCTAssertEqual(
            VideoDownloadError.classify(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
            .insufficientStorage)
        XCTAssertEqual(
            VideoDownloadError.classify(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)),
            .writePermissionDenied)
        XCTAssertEqual(
            VideoDownloadError.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))),
            .insufficientStorage)
    }

    func testClassifyPassesThroughKnownAndWrapsUnknown() {
        XCTAssertEqual(VideoDownloadError.classify(VideoDownloadError.drmProtected), .drmProtected)
        let unknown = NSError(domain: "com.example.weird", code: 42,
                              userInfo: [NSLocalizedDescriptionKey: "boom"])
        XCTAssertEqual(VideoDownloadError.classify(unknown), .downloadFailed(message: "boom"))
    }

    // MARK: - Helpers

    /// Polls `condition` (up to 2 s) and fails the test if it never holds.
    /// Uses the test-only ContinuousClock, no wall-clock Date math.
    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "condition not met within 2s", file: file, line: line)
    }

    private func minimalChart(title: String, artist: String, extraHeaders: [String] = []) -> String {
        (["#TITLE:\(title)", "#ARTIST:\(artist)", "#BPM:120"] + extraHeaders
            + [": 0 4 0 la", "E", ""]).joined(separator: "\n")
    }

    private func makeSongFolder(named name: String, chart: String) throws -> URL {
        let folder = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(chart.utf8).write(to: folder.appendingPathComponent("\(name).txt"))
        return folder
    }

    /// Synthesizes a video container holding one second of 440 Hz sine as an
    /// AAC track — the smallest honest stand-in for a downloaded video.
    private static func writeVideoContainerWithSineAudio(to url: URL, seconds: Double) throws {
        let sampleRate = 44_100.0
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        writer.add(input)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription), "format description")

        let frameCount = Int(seconds * sampleRate)
        let samples = (0..<frameCount).map { frame in
            Int16(sin(2 * .pi * 440 * Double(frame) / sampleRate) * 12_000)
        }
        let byteCount = frameCount * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer), "block buffer")
        try samples.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer!,
                offsetIntoDestination: 0, dataLength: byteCount), "fill block buffer")
        }
        var sampleBuffer: CMSampleBuffer?
        try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer!, formatDescription: formatDescription!,
            sampleCount: frameCount, presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer), "sample buffer")

        guard writer.startWriting() else {
            throw XCTSkip("cannot start AVAssetWriter: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)
        while !input.isReadyForMoreMediaData { usleep(10_000) }
        input.append(sampleBuffer!)
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw XCTSkip("fixture encode failed: \(String(describing: writer.error))")
        }
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "CoreMedia \(what) failed"])
        }
    }
}

// MARK: - Mocks

/// Transport double: records start/end order, emits fake progress, and can
/// hold its next N fetches open until `releaseAll()`.
private final class MockVideoFetcher: VideoFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    /// How many upcoming fetches should block awaiting `releaseAll()`.
    var holdNext = 0

    var events: [String] { lock.withLock { _events } }

    func releaseAll() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { held.removeAll() }
            return held
        }
        continuations.forEach { $0.resume() }
    }

    func fetchVideo(
        from source: URL, into folder: URL, baseName: String, reporter: VideoFetchReporter
    ) async throws -> URL {
        lock.withLock { _events.append("start:\(baseName)") }
        reporter.onProgress(DownloadProgress(phase: .fetchingVideo, fractionCompleted: 0.5))
        let shouldHold = lock.withLock { () -> Bool in
            guard holdNext > 0 else { return false }
            holdNext -= 1
            return true
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { held.append(continuation) }
            }
        }
        try Task.checkCancellation()
        lock.withLock { _events.append("end:\(baseName)") }
        reporter.onProgress(DownloadProgress(phase: .fetchingVideo, fractionCompleted: 1))
        return folder.appendingPathComponent(baseName).appendingPathExtension("mp4")
    }
}

/// Extraction double: touches no media, just returns the destination.
private struct MockAudioExtractor: AudioExtracting {
    func extractAudio(from videoURL: URL, to outputURL: URL) async throws -> URL {
        outputURL
    }
}

/// Notifier double recording terminal events.
private final class MockNotifier: DownloadNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _completed: [String] = []
    private var _failed: [String] = []

    var completed: [String] { lock.withLock { _completed } }
    var failed: [String] { lock.withLock { _failed } }

    func downloadDidComplete(songName: String, paths: VideoPaths) {
        lock.withLock { _completed.append(songName) }
    }

    func downloadDidFail(songName: String, message: String) {
        lock.withLock { _failed.append(songName) }
    }
}

/// Thread-safe accumulator for reporter progress snapshots.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [DownloadProgress] = []

    var snapshots: [DownloadProgress] { lock.withLock { _snapshots } }

    func append(_ snapshot: DownloadProgress) {
        lock.withLock { _snapshots.append(snapshot) }
    }
}
