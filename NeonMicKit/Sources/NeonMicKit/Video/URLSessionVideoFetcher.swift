import Foundation

/// Downloads a video from a *direct* media URL (`https://…/clip.mp4`, or a
/// `file://` URL in tests) with URLSession.
///
/// This transport cannot resolve page URLs — YouTube links go through
/// ``YtDlpVideoFetcher``. Bytes stream straight to disk in 64 KiB slices, so
/// memory stays flat regardless of file size.
public struct URLSessionVideoFetcher: VideoFetching {

    private let session: URLSession

    /// Creates a fetcher; `session` defaults to `URLSession.shared`.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchVideo(
        from source: URL,
        into folder: URL,
        baseName: String,
        reporter: VideoFetchReporter
    ) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: source)
        reporter.onURLSessionTask(bytes.task)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VideoDownloadError.badServerResponse(statusCode: http.statusCode)
        }

        // Keep the source's container; anything but .mov normalizes to .mp4
        // (the service only routes direct mp4/mov/m4v URLs here).
        let ext = source.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
        let destination = folder.appendingPathComponent(baseName).appendingPathExtension(ext)
        let staging = folder.appendingPathComponent(".\(baseName).download")

        let fileManager = FileManager.default
        fileManager.createFile(atPath: staging.path, contents: nil)
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }

        let expected = response.expectedContentLength // -1 when unknown
        var received: Int64 = 0
        var chunk = Data(capacity: 64 * 1024)

        func flush() throws {
            guard !chunk.isEmpty else { return }
            try handle.write(contentsOf: chunk)
            received += Int64(chunk.count)
            chunk.removeAll(keepingCapacity: true)
            reporter.onProgress(DownloadProgress(
                phase: .fetchingVideo,
                fractionCompleted: expected > 0 ? min(1, Double(received) / Double(expected)) : 0,
                bytesReceived: received,
                expectedBytes: expected > 0 ? expected : nil
            ))
        }

        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 64 * 1024 {
                    try flush()
                }
            }
            try flush()
        } catch {
            try? fileManager.removeItem(at: staging)
            // URLSession surfaces our own cancelDownload as NSURLErrorCancelled.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }

        try handle.close()
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        reporter.onProgress(DownloadProgress(
            phase: .fetchingVideo,
            fractionCompleted: 1,
            bytesReceived: received,
            expectedBytes: expected > 0 ? expected : nil
        ))
        return destination
    }
}
