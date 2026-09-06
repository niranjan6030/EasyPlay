import Foundation

public enum InstallError: LocalizedError {
    case installerFailed(log: String, diagnoses: [Diagnosis])
    case executableNotFound(glob: String)
    case unsupportedGame(Recipe)
    case steamNotInstalled

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

        onProgress?("Running the \(gameTitle) installer…")

        let arguments = [installerURL.path] + (recipe?.install.installerArguments ?? [])
        let result = try wine.run(arguments, recipe: recipe, verbosity: .diagnostic,
                                  timeout: 7200, onOutput: nil)

        let logURL = try writeLog(result.combinedOutput, bottle: bottle, step: "install")
        onProgress?("Installer finished. Log saved to \(logURL.lastPathComponent).")

        // Installers frequently exit non-zero and still succeed, so the exit code
        // alone doesn't decide the outcome — finding the executable does.
        let glob = recipe?.launch.executableGlob ?? "**/*.exe"
        guard let executable = ExecutableFinder().find(glob: glob, in: bottle) else {
            let diagnoses = LogClassifier(recipe: recipe)
                .classify(log: result.combinedOutput, exitCode: result.exitCode)
            if diagnoses.isEmpty {
                throw InstallError.executableNotFound(glob: glob)
            }
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
