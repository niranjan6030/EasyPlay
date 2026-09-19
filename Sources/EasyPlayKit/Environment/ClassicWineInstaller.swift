import Foundation

/// Downloads and installs Classic Wine, the engine EasyPlay uses for 32-bit games.
///
/// Classic Wine is Wine 8 built from the source CodeWeavers publishes for
/// CrossOver 23, packaged by the open-source Sikarugir project. It arrives in
/// two parts: the engine itself, and the Mac libraries it was built against,
/// which Sikarugir ships inside its wrapper template. EasyPlay keeps only the
/// libraries and discards the rest of the template.
///
/// Both downloads are pinned to exact files and checked against their published
/// SHA-256 digests before anything is unpacked, so a changed or corrupted file
/// is refused rather than run.
public struct ClassicWineInstaller {
    public typealias ProgressHandler = (String) -> Void

    public struct Download {
        public let url: URL
        public let sha256: String
        public let megabytes: Int
    }

    public static let engine = Download(
        url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX23.7.1_4.tar.xz")!,
        sha256: "f1519042639f37ef20240d5f5a90911568b48bec4816ee1c6e1c44a33c69b64c",
        megabytes: 166)

    public static let libraries = Download(
        url: URL(string: "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.12.tar.xz")!,
        sha256: "74aa180bf7d7cdd529c6447eedf36a0d7149ea8e2dcc32d3de131b260c9c5eb8",
        megabytes: 83)

    /// Where the engine lives once installed:
    /// `Classic Wine/wswine.bundle/bin/wine` and `Classic Wine/Frameworks/`.
    public static var directory: URL {
        AppPaths.runtimesDirectory.appendingPathComponent("Classic Wine", isDirectory: true)
    }

    public static var binDirectory: URL {
        directory.appendingPathComponent("wswine.bundle/bin", isDirectory: true)
    }

    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binDirectory.appendingPathComponent("wine").path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("Frameworks").path)
    }

    public enum InstallError: LocalizedError {
        case checksumMismatch(String)
        case unexpectedLayout(String)

        public var errorDescription: String? {
            switch self {
            case .checksumMismatch(let name):
                return "\(name) didn't match its published checksum, so EasyPlay deleted it instead of installing it. Try again; if it keeps happening, the file on GitHub has changed."
            case .unexpectedLayout(let detail):
                return "The download wasn't laid out as expected (\(detail)), so nothing was installed."
            }
        }
    }

    private let runner: ProcessRunner
    private let fileManager: FileManager

    public init(runner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func install(onProgress: ProgressHandler? = nil) throws {
        try AppPaths.ensureDirectories()
        // Staged next to the destination so the final step is a rename on the
        // same volume, and a failed install never leaves a half-made engine.
        let staging = AppPaths.runtimesDirectory
            .appendingPathComponent(".classic-wine-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let engineArchive = try fetch(Self.engine, named: "the Wine 8 engine", into: staging, onProgress: onProgress)
        let librariesArchive = try fetch(Self.libraries, named: "its support libraries", into: staging, onProgress: onProgress)

        onProgress?("Unpacking…")
        let assembled = staging.appendingPathComponent("Classic Wine", isDirectory: true)
        try fileManager.createDirectory(at: assembled, withIntermediateDirectories: true)
        try runner.runChecked("/usr/bin/tar", ["-xJf", engineArchive.path, "-C", assembled.path], timeout: 600)
        guard fileManager.isExecutableFile(atPath: assembled.appendingPathComponent("wswine.bundle/bin/wine").path) else {
            throw InstallError.unexpectedLayout("no wswine.bundle/bin/wine in the engine archive")
        }

        // Only the template's Frameworks folder is needed.
        let template = staging.appendingPathComponent("template", isDirectory: true)
        try fileManager.createDirectory(at: template, withIntermediateDirectories: true)
        try runner.runChecked("/usr/bin/tar", ["-xJf", librariesArchive.path, "-C", template.path,
                                               "*/Contents/Frameworks"], timeout: 600)
        guard let app = try fileManager.contentsOfDirectory(at: template, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.unexpectedLayout("no app bundle in the libraries archive")
        }
        try fileManager.moveItem(at: app.appendingPathComponent("Contents/Frameworks"),
                                 to: assembled.appendingPathComponent("Frameworks"))

        // Files from the internet carry a quarantine flag, and Gatekeeper would
        // otherwise stop Wine the first time a game starts.
        _ = try? runner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", assembled.path], timeout: 120)

        onProgress?("Installing…")
        if fileManager.fileExists(atPath: Self.directory.path) {
            try fileManager.removeItem(at: Self.directory)
        }
        try fileManager.moveItem(at: assembled, to: Self.directory)
        onProgress?("Classic Wine is installed.")
    }

    private func fetch(_ download: Download, named name: String, into directory: URL,
                       onProgress: ProgressHandler?) throws -> URL {
        onProgress?("Downloading \(name) (\(download.megabytes) MB)…")
        let destination = directory.appendingPathComponent(download.url.lastPathComponent)
        try runner.runChecked("/usr/bin/curl", ["-fsSL", "--retry", "3", "-o", destination.path,
                                                download.url.absoluteString], timeout: 1800)
        onProgress?("Checking \(name)…")
        let digest = try runner.runChecked("/usr/bin/shasum", ["-a", "256", destination.path], timeout: 120)
            .standardOutput.split(separator: " ").first.map(String.init) ?? ""
        guard digest == download.sha256 else {
            try? fileManager.removeItem(at: destination)
            throw InstallError.checksumMismatch(download.url.lastPathComponent)
        }
        return destination
    }
}
