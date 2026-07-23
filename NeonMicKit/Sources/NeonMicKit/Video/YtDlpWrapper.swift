import Foundation

/// Locates the system `yt-dlp` executable for the video subsystem.
///
/// A macOS GUI app does **not** inherit the Terminal's `PATH`, so relying on
/// `PATH` alone would miss a Homebrew install that works fine in the shell.
/// This wrapper checks the well-known absolute install locations first and only
/// then falls back to `PATH`. The resolved path is cached once in
/// ``executablePath`` for the process lifetime.
///
/// Detection is injectable (`environment`, `homeDirectory`, `fileManager`) so
/// it can be unit-tested without touching the real filesystem or PATH.
public final class YtDlpWrapper {

    private init() {}

    /// Well-known absolute install locations, tried **in order** before `PATH`.
    /// `~` is expanded against the caller's home directory.
    public static let searchPaths = [
        "/opt/homebrew/bin/yt-dlp",   // Homebrew — Apple Silicon
        "/usr/local/bin/yt-dlp",      // Homebrew — Intel
        "/opt/local/bin/yt-dlp",      // MacPorts
        "~/.local/bin/yt-dlp",        // pip / pipx --user
        "/usr/bin/yt-dlp",            // system
    ]

    /// The command that installs yt-dlp (plus ffmpeg, needed to merge 1080p).
    public static let installCommand = "brew install yt-dlp ffmpeg"

    /// The resolved yt-dlp executable, looked up once with the real environment
    /// (nil when not installed). Cached for the process lifetime — a yt-dlp
    /// installed *after* launch is only picked up on the next run (hence the
    /// "relaunch" hint in the not-found error).
    public static let executablePath: URL? = locate()

    /// Returns the resolved executable, or throws
    /// ``VideoDownloadError/ytDlpNotFound`` — whose message lists the searched
    /// paths, the `brew install` command, and to relaunch afterwards.
    ///
    /// Injectable for tests; uses the real environment by default.
    @discardableResult
    public static func findExecutablePath(
        searchPaths: [String] = YtDlpWrapper.searchPaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let url = locate(
            searchPaths: searchPaths, environment: environment,
            homeDirectory: homeDirectory, fileManager: fileManager)
        else {
            throw VideoDownloadError.ytDlpNotFound
        }
        return url
    }

    /// Finds yt-dlp by checking, in order: the `NEONMIC_YTDLP` override, the
    /// absolute ``searchPaths``, then every directory on `PATH`. Returns the
    /// first executable found, or nil.
    public static func locate(
        searchPaths: [String] = YtDlpWrapper.searchPaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> URL? {
        for path in orderedCandidatePaths(
            searchPaths: searchPaths, environment: environment, homeDirectory: homeDirectory)
        where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// The ordered, de-duplicated list of paths to probe: the `NEONMIC_YTDLP`
    /// override, the absolute locations, then `PATH` entries. `~/…` is expanded
    /// against `homeDirectory`.
    static func orderedCandidatePaths(
        searchPaths: [String],
        environment: [String: String],
        homeDirectory: String
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            guard !raw.isEmpty else { return }
            let path = raw.hasPrefix("~/") ? homeDirectory + raw.dropFirst() : raw
            if seen.insert(path).inserted { ordered.append(path) }
        }

        if let override = environment["NEONMIC_YTDLP"] { add(override) }
        searchPaths.forEach(add)
        if let pathVariable = environment["PATH"] {
            for directory in pathVariable.split(separator: ":") where !directory.isEmpty {
                add("\(directory)/yt-dlp")
            }
        }
        return ordered
    }
}
