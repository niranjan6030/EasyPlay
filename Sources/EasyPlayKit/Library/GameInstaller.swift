import Foundation

public enum InstallError: LocalizedError {
    case installerFailed(log: String, diagnoses: [Diagnosis])
    case executableNotFound(glob: String)
    case unsupportedGame(Recipe)
    case steamNotInstalled
    case steamDownloadIncomplete(appID: String, state: SteamInstaller.State)

    public var errorDescription: String? {
        switch self {
        case .installerFailed(_, let diagnoses):
            return diagnoses.first?.explanation ?? "The installer didn't finish."
        case .executableNotFound(let glob):
            return "The install finished, but EasyPlay couldn't find the game's program file (expected something matching \(glob))."
        case .unsupportedGame(let recipe):
            return recipe.compatibility.unsupportedReason?.explanation
                ?? "\(recipe.title) can't run on a Mac."
        case .steamNotInstalled:
            return "Steam isn't in this bottle yet."
        case .steamDownloadIncomplete(_, let state):
            switch state {
            case .steamNotInstalled:
                return "Steam isn't in this bottle, so the download can't be followed."
            case .notStarted:
                return "Steam never started downloading this game. Sign in to Steam and begin the download, then try again."
            case .downloading(let progress):
                let percent = progress.map { " (\(Int($0 * 100))% done)" } ?? ""
                return "The download hadn't finished\(percent). EasyPlay stopped waiting, but Steam will carry on - come back when it's done."
            case .installed:
                return "The download finished after all."
            }
        }
    }
}

/// Runs a game's installer inside a bottle and records the result.
public struct GameInstaller {
    public typealias ProgressHandler = (String) -> Void

    private let backend: WineBackend
    private let runner: ProcessRunner
    private let store: GameStore

    public init(backend: WineBackend,
                runner: ProcessRunner = ProcessRunner(),
                store: GameStore = GameStore()) {
        self.backend = backend
        self.runner = runner
        self.store = store
    }

    /// Runs a Windows installer inside `bottle`, then registers what it produced.
    ///
    /// Wine can execute an installer straight from a Mac path, so nothing is
    /// copied into the bottle first — the installer decides where its files go,
    /// exactly as it would on Windows.
    @discardableResult
    public func install(installerAt installerURL: URL,
                        into bottle: Bottle,
                        recipe: Recipe?,
                        title: String? = nil,
                        onProgress: ProgressHandler? = nil) throws -> InstalledGame {

        if let recipe, recipe.compatibility.rating == .notSupported {
            throw InstallError.unsupportedGame(recipe)
        }

        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)
        let gameTitle = title ?? recipe?.title ?? installerURL.deletingPathExtension().lastPathComponent

        let isSilent = !(recipe?.install.installerArguments ?? []).isEmpty
        if isSilent {
            onProgress?("Running the \(gameTitle) installer…")
        } else {
            // Most installers are wizards. Nothing previously said so, which
            // made an on-screen installer look like EasyPlay hanging.
            onProgress?("The \(gameTitle) installer is now on screen — follow its steps.")
            onProgress?("EasyPlay carries on once the installer closes.")
        }

        // Record what is already here, so afterwards we can tell what the
        // installer actually added.
        let finder = ExecutableFinder()
        let before = finder.snapshot(of: bottle)
        let arguments = [installerURL.path] + (recipe?.install.installerArguments ?? [])
        let result = try wine.run(arguments, recipe: recipe, verbosity: .diagnostic,
                                  timeout: 7200, onOutput: nil)

        let logURL = try writeLog(result.combinedOutput, bottle: bottle, step: "install")
        onProgress?("Installer finished. Log saved to \(logURL.lastPathComponent).")

        // Installers frequently exit non-zero and still succeed, so the exit code
        // alone doesn't decide the outcome — finding the executable does.
        let glob = recipe?.launch.executableGlob ?? "**/*.exe"
        guard let executable = finder.find(glob: glob, in: bottle, ignoring: before) else {
            var diagnoses = LogClassifier(recipe: recipe)
                .classify(log: result.combinedOutput, exitCode: result.exitCode)

            // Nothing new on disk means the installer never got as far as
            // installing — cancelled, crashed, or refused to run.
            diagnoses.insert(Diagnosis(
                id: "installer-produced-nothing",
                title: "The installer closed without installing anything",
                explanation: "\(gameTitle) isn't in this bottle: the installer ran but left no program behind. That usually means it was cancelled or closed early, or it needs a Windows component this bottle doesn't have yet. The bottle is still here, so you can try the installer again.",
                remedy: nil,
                evidence: LogClassifier.interestingLines(from: result.combinedOutput).joined(separator: "\n")
            ), at: 0)

            throw InstallError.installerFailed(log: result.combinedOutput, diagnoses: diagnoses)
        }

        let relativePath = executable.path.replacingOccurrences(of: bottle.url.path + "/", with: "")
        let game = InstalledGame(
            title: gameTitle,
            bottleID: bottle.id,
            recipeID: recipe?.id,
            executableRelativePath: relativePath,
            compatibilityRating: recipe?.compatibility.rating ?? .untested
        )
        try store.add(game)
        onProgress?("\(gameTitle) is installed.")
        return game
    }

    /// Installs a game that is only sold through Steam.
    ///
    /// The shape of this is dictated by the one thing EasyPlay must not do:
    /// handle the user's Steam credentials. So it installs the client, opens the
    /// game's install page, and then *waits* — reading Steam's own manifest to
    /// see when the download finishes — while the user signs in and clicks
    /// Install themselves.
    @discardableResult
    public func installFromSteam(recipe: Recipe,
                                 into bottle: Bottle,
                                 waitForDownload: Bool = true,
                                 timeout: TimeInterval = 6 * 3600,
                                 shouldContinue: @escaping () -> Bool = { true },
                                 onProgress: ProgressHandler? = nil) throws -> InstalledGame {

        if recipe.compatibility.rating == .notSupported {
            throw InstallError.unsupportedGame(recipe)
        }
        guard let appID = recipe.install.steamAppID else {
            throw InstallError.executableNotFound(glob: "a Steam app ID in the \(recipe.title) preset")
        }

        let steam = SteamInstaller(backend: backend, runner: runner)
        try steam.installSteam(into: bottle, recipe: recipe, onProgress: onProgress)

        onProgress?("Opening Steam. Sign in, then start the \(recipe.title) download.")
        _ = try steam.requestInstall(appID: appID, in: bottle, recipe: recipe)

        guard waitForDownload else {
            throw InstallError.steamDownloadIncomplete(
                appID: appID, state: steam.state(appID: appID, in: bottle))
        }

        let manifest = try steam.waitForGame(
            appID: appID, in: bottle, timeout: timeout,
            shouldContinue: shouldContinue
        ) { state in
            switch state {
            case .steamNotInstalled: onProgress?("Waiting for Steam…")
            case .notStarted: onProgress?("Waiting for you to start the download in Steam…")
            case .downloading(let progress):
                onProgress?(progress.map { "Downloading \(recipe.title) — \(Int($0 * 100))%" }
                            ?? "Downloading \(recipe.title)…")
            case .installed: onProgress?("Download finished.")
            }
        }

        // Prefer searching inside the folder Steam reported, so a bottle holding
        // several games can't return the wrong executable.
        let executable = ExecutableFinder().find(glob: recipe.launch.executableGlob, in: bottle)
        guard let executable else {
            throw InstallError.executableNotFound(glob: recipe.launch.executableGlob)
        }

        let game = InstalledGame(
            title: manifest.name ?? recipe.title,
            bottleID: bottle.id,
            recipeID: recipe.id,
            executableRelativePath: executable.path.replacingOccurrences(of: bottle.url.path + "/", with: ""),
            compatibilityRating: recipe.compatibility.rating
        )
        try store.add(game)
        onProgress?("\(game.title) is installed.")
        return game
    }

    /// Registers a game that is already present in a bottle — used after a Steam
    /// download, where the installer is Steam itself rather than a setup file.
    @discardableResult
    public func registerExistingGame(in bottle: Bottle,
                                     recipe: Recipe,
                                     title: String? = nil) throws -> InstalledGame {
        guard let executable = ExecutableFinder().find(glob: recipe.launch.executableGlob, in: bottle) else {
            throw InstallError.executableNotFound(glob: recipe.launch.executableGlob)
        }
        let game = InstalledGame(
            title: title ?? recipe.title,
            bottleID: bottle.id,
            recipeID: recipe.id,
            executableRelativePath: executable.path.replacingOccurrences(of: bottle.url.path + "/", with: ""),
            compatibilityRating: recipe.compatibility.rating
        )
        try store.add(game)
        return game
    }

    private func writeLog(_ contents: String, bottle: Bottle, step: String) throws -> URL {
        try AppPaths.ensureDirectories()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = AppPaths.logsDirectory.appendingPathComponent("\(bottle.name)-\(step)-\(stamp).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
