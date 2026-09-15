import Foundation

public enum InstallError: LocalizedError {
    case installerFailed(log: String, diagnoses: [Diagnosis])
    case executableNotFound(glob: String)
    case unsupportedGame(Recipe)
    case steamSignInRequired

    public var errorDescription: String? {
        switch self {
        case .installerFailed(_, let diagnoses):
            return diagnoses.first?.explanation ?? "The installer didn't finish."
        case .executableNotFound(let glob):
            return "The install finished, but EasyPlay couldn't find the game's program file (expected something matching \(glob))."
        case .unsupportedGame(let recipe):
            return recipe.compatibility.unsupportedReason?.explanation
                ?? "\(recipe.title) can't run on a Mac."
        case .steamSignInRequired:
            return SteamCMDOutput.Failure.needsSignIn.explanation
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

    /// Folder inside a bottle that a Steam game is downloaded into.
    public static func steamInstallDirectory(for recipe: Recipe, in bottle: Bottle) -> URL {
        let folder = recipe.title.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
        return bottle.driveC
            .appendingPathComponent("Games", isDirectory: true)
            .appendingPathComponent(folder.isEmpty ? recipe.id : folder, isDirectory: true)
    }

    /// Installs a game sold through Steam, using Valve's native macOS SteamCMD.
    ///
    /// Fails fast: if the account isn't signed in, this says so immediately
    /// rather than starting a download that can only fail. EasyPlay never sees
    /// the password — signing in happens in SteamCMD's own window.
    @discardableResult
    public func installFromSteam(recipe: Recipe,
                                 into bottle: Bottle,
                                 username: String,
                                 onProgress: ProgressHandler? = nil,
                                 onPercent: ((Double) -> Void)? = nil,
                                 shouldContinue: @escaping () -> Bool = { true }) throws -> InstalledGame {

        if recipe.compatibility.rating == .notSupported {
            throw InstallError.unsupportedGame(recipe)
        }
        guard let appID = recipe.install.steamAppID else {
            throw InstallError.executableNotFound(glob: "a Steam app ID in the \(recipe.title) preset")
        }

        let steam = SteamCMD(runner: runner)
        if !steam.isInstalled {
            try steam.install(onProgress: onProgress)
        }

        onProgress?("Checking your Steam sign-in…")
        guard steam.isSignedIn(username: username) else {
            throw InstallError.steamSignInRequired
        }

        let directory = Self.steamInstallDirectory(for: recipe, in: bottle)
        let finder = ExecutableFinder()
        let before = finder.snapshot(of: bottle)

        onProgress?("Downloading \(recipe.title) from Steam…")
        do {
            try steam.download(appID: appID, into: directory, username: username,
                               onProgress: onProgress, onPercent: onPercent,
                               shouldContinue: shouldContinue)
        } catch let error as SteamCMD.SteamCMDError where error.failure == .needsSignIn {
            throw InstallError.steamSignInRequired
        }

        guard let executable = finder.find(glob: recipe.launch.executableGlob, in: bottle, ignoring: before)
                ?? finder.find(glob: recipe.launch.executableGlob, in: bottle) else {
            throw InstallError.executableNotFound(glob: recipe.launch.executableGlob)
        }

        let manifest = SteamAppManifest.load(appID: appID, installDirectory: directory)
        let game = InstalledGame(
            title: manifest?.name ?? recipe.title,
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
