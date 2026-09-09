import Foundation

public struct LaunchOutcome {
    public let game: InstalledGame
    public let exitCode: Int32
    public let logURL: URL?
    /// Empty when the game ran and quit normally.
    public let diagnoses: [Diagnosis]

    public var succeeded: Bool { exitCode == 0 && diagnoses.isEmpty }
}

/// Starts an installed game.
///
/// The whole point of the preset system arrives here: by this stage the bottle
/// is already configured, so launching is a single call with no per-game special
/// cases — the recipe supplied them all earlier.
public struct GameLauncher {
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

    /// Runs the game and waits for it to exit.
    ///
    /// Waiting is what makes readable errors possible: a game that dies two
    /// seconds after launch has already written the reason to its log, and this
    /// is where we catch it instead of leaving the user with a window that
    /// flashed and vanished.
    /// `timeout` stops the game after a fixed period instead of waiting for the
    /// player to quit. That is what the "check this bottle works" flow uses: it
    /// starts a program, confirms it stayed up, and closes it again.
    public func launch(_ game: InstalledGame,
                       in bottle: Bottle,
                       recipe: Recipe?,
                       verbosity: WineRunner.Verbosity = .diagnostic,
                       timeout: TimeInterval? = nil,
                       onOutput: ProcessRunner.OutputHandler? = nil) throws -> LaunchOutcome {

        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)
        let executable = game.executableURL(in: bottle)
        let workingDirectory = (recipe?.launch.workingDirectoryFromExecutable ?? true)
            ? executable.deletingLastPathComponent()
            : nil

        let preflight = self.preflight(executable: executable, recipe: recipe)

        // A Steam game has to start through Steam: the client provides the
        // Steamworks API the game links against, and launching the executable
        // directly usually ends in "Steam is not running".
        let arguments: [String]
        if let recipe, recipe.install.kind == .steam, let appID = recipe.install.steamAppID {
            arguments = [SteamInstaller.steamExecutable(in: bottle).path,
                         "-no-cef-sandbox", "-applaunch", appID] + recipe.launch.arguments
        } else {
            arguments = [executable.path] + (recipe?.launch.arguments ?? [])
        }

        let result: CommandResult
        do {
            result = try wine.run(arguments, recipe: recipe, verbosity: verbosity,
                                  workingDirectory: workingDirectory, timeout: timeout,
                                  onOutput: onOutput)
        } catch ProcessError.timedOut {
            // Hitting the timeout means the program was still running, which for
            // a bottle check is the successful outcome. Pre-flight warnings still
            // apply, though — a game that runs on the wrong renderer runs badly
            // rather than failing, which is exactly when saying so matters most.
            try? store.update(id: game.id) { $0.lastPlayedAt = Date() }
            _ = try? wine.shutdown()
            return LaunchOutcome(game: game, exitCode: 0, logURL: nil, diagnoses: preflight)
        }

        try? store.update(id: game.id) { $0.lastPlayedAt = Date() }

        let diagnoses = preflight + LogClassifier(recipe: recipe)
            .classify(log: result.combinedOutput, exitCode: result.exitCode)

        let logURL = try? writeLog(result.combinedOutput, bottle: bottle)
        return LaunchOutcome(game: game, exitCode: result.exitCode,
                             logURL: logURL, diagnoses: diagnoses)
    }

    /// Checks that can be made before the game runs at all.
    ///
    /// Wine will happily start a 32-bit game whose preset asks for D3DMetal and
    /// quietly serve it the OpenGL renderer instead. The game then runs badly and
    /// reports a graphics card that does not exist, which is impossible to
    /// diagnose from the log. Saying so up front is the whole point of EasyPlay.
    public func preflight(executable: URL, recipe: Recipe?) -> [Diagnosis] {
        guard let recipe else { return [] }
        let architecture = WindowsExecutable.architecture(of: executable)
        let wanted = recipe.graphics.backend
        guard !backend.supports(wanted, for: architecture) else { return [] }

        return [Diagnosis(
            id: "translator-architecture-mismatch",
            title: "\(wanted.displayName) can't be used by this program",
            explanation: "\(recipe.title) is a \(architecture.displayName) program, and \(wanted.displayName) only works with 64-bit ones. Wine will fall back to its built-in renderer, which is much slower. This is a limit of the compatibility engine, not something a preset can change.",
            remedy: .switchGraphics(.wineD3D),
            evidence: "\(executable.lastPathComponent) is \(architecture.displayName) (PE machine type \(architecture.rawValue))"
        )]
    }

    private func writeLog(_ contents: String, bottle: Bottle) throws -> URL {
        try AppPaths.ensureDirectories()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = AppPaths.logsDirectory.appendingPathComponent("\(bottle.name)-play-\(stamp).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
