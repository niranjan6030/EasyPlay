import Foundation

/// Installs the Steam client into a bottle and follows a game download through it.
///
/// Most modern PC games have no standalone installer — they are a Steam library
/// entry. Supporting only `setup.exe` means supporting almost nothing anyone
/// actually wants to play, which is why this exists.
///
/// EasyPlay never touches the user's Steam credentials. It installs the client,
/// opens it, and hands over; the user signs in themselves, in Steam's own
/// window, with their own two-factor. EasyPlay resumes by reading Steam's
/// manifest files to see when the download has finished.
public struct SteamInstaller {
    public typealias ProgressHandler = (String) -> Void

    /// Valve's official installer. EasyPlay downloads Steam from Valve and
    /// nowhere else.
    public static let installerURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    public enum State: Equatable {
        case steamNotInstalled
        /// Steam is installed but the game has no manifest yet — the user has
        /// not started the download.
        case notStarted
        case downloading(progress: Double?)
        case installed(SteamAppManifest)
    }

    private let backend: WineBackend
    private let runner: ProcessRunner
    private let fileManager: FileManager

    public init(backend: WineBackend,
                runner: ProcessRunner = ProcessRunner(),
                fileManager: FileManager = .default) {
        self.backend = backend
        self.runner = runner
        self.fileManager = fileManager
    }

    // MARK: - The Steam client

    public static func steamExecutable(in bottle: Bottle) -> URL {
        bottle.driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe")
    }

    public func isSteamInstalled(in bottle: Bottle) -> Bool {
        fileManager.fileExists(atPath: Self.steamExecutable(in: bottle).path)
    }

    /// Downloads Valve's installer to `directory`.
    public func downloadInstaller(to directory: URL,
                                  onProgress: ProgressHandler? = nil) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("SteamSetup.exe")

        if fileManager.fileExists(atPath: destination.path),
           let size = try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int,
           size > 1_000_000 {
            onProgress?("Using the Steam installer already downloaded.")
            return destination
        }

        onProgress?("Downloading Steam from Valve…")
        try runner.runChecked("/usr/bin/curl", [
            "-fsSL", "--retry", "3", "--retry-delay", "2",
            "-o", destination.path, Self.installerURL.absoluteString,
        ], timeout: 600)
        return destination
    }

    /// Runs Valve's installer inside the bottle, unattended.
    public func installSteam(into bottle: Bottle,
                             recipe: Recipe?,
                             onProgress: ProgressHandler? = nil) throws {
        if isSteamInstalled(in: bottle) {
            onProgress?("Steam is already in this bottle.")
            return
        }

        let installer = try downloadInstaller(to: AppPaths.runtimesDirectory, onProgress: onProgress)
        onProgress?("Installing the Steam client…")

        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)
        // Valve's installer is NSIS; /S runs it silently.
        _ = try wine.run([installer.path, "/S"], recipe: recipe,
                         verbosity: .diagnostic, timeout: 1800)

        guard isSteamInstalled(in: bottle) else {
            throw InstallError.installerFailed(
                log: "Steam did not appear at \(Self.steamExecutable(in: bottle).path)",
                diagnoses: [Diagnosis(
                    id: "steam-install-failed",
                    title: "Steam didn't install",
                    explanation: "The Steam installer ran but didn't leave a working client in this game's bottle. Deleting the bottle and trying again usually fixes it.",
                    remedy: .recreateBottle
                )]
            )
        }
        onProgress?("Steam is installed.")
    }

    /// Starts Steam and returns without waiting — the user needs it on screen.
    ///
    /// `-no-cef-sandbox` is required under Wine: Steam's embedded Chromium
    /// cannot create its sandbox and the client hangs on a grey window without it.
    @discardableResult
    public func launchSteam(in bottle: Bottle,
                            recipe: Recipe?,
                            arguments: [String] = []) throws -> Process {
        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)
        return try runner.launch(
            backend.wine64.path,
            [Self.steamExecutable(in: bottle).path, "-no-cef-sandbox"] + arguments,
            environment: wine.environment(recipe: recipe, verbosity: .play)
        )
    }

    /// Asks Steam to open a game's install dialogue.
    @discardableResult
    public func requestInstall(appID: String, in bottle: Bottle, recipe: Recipe?) throws -> Process {
        try launchSteam(in: bottle, recipe: recipe, arguments: ["steam://install/\(appID)"])
    }

    // MARK: - Following the download

    public func state(appID: String, in bottle: Bottle) -> State {
        guard isSteamInstalled(in: bottle) else { return .steamNotInstalled }
        guard let manifest = SteamAppManifest.load(appID: appID, in: bottle) else { return .notStarted }
        if manifest.isFullyInstalled { return .installed(manifest) }
        return .downloading(progress: manifest.downloadProgress)
    }

    /// Polls Steam's manifest until the game is fully installed.
    ///
    /// Deliberately patient: a 50 GB download is measured in hours, and the user
    /// still has to sign in and press the button before it even starts.
    public func waitForGame(appID: String,
                            in bottle: Bottle,
                            timeout: TimeInterval = 6 * 3600,
                            pollInterval: TimeInterval = 5,
                            shouldContinue: () -> Bool = { true },
                            onProgress: ((State) -> Void)? = nil) throws -> SteamAppManifest {
        let deadline = Date().addingTimeInterval(timeout)
        var lastReported: State?

        while Date() < deadline, shouldContinue() {
            let current = state(appID: appID, in: bottle)
            if current != lastReported {
                onProgress?(current)
                lastReported = current
            }
            if case .installed(let manifest) = current { return manifest }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        throw InstallError.steamDownloadIncomplete(appID: appID, state: state(appID: appID, in: bottle))
    }

    /// Stops the Steam client in this bottle.
    public func shutdownSteam(in bottle: Bottle, recipe: Recipe?) {
        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)
        _ = try? runner.run(backend.wine64.path,
                            [Self.steamExecutable(in: bottle).path, "-shutdown"],
                            environment: wine.environment(recipe: recipe),
                            timeout: 60)
    }
}
