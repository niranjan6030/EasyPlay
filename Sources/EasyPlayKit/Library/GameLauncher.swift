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

        let arguments = [executable.path] + (recipe?.launch.arguments ?? [])

        let result: CommandResult
        do {
            result = try wine.run(arguments, recipe: recipe, verbosity: verbosity,
                                  workingDirectory: workingDirectory, timeout: timeout,
                                  onOutput: onOutput)
        } catch ProcessError.timedOut {
            // Hitting the timeout means the program was still running, which for
            // a bottle check is the successful outcome.
            try? store.update(id: game.id) { $0.lastPlayedAt = Date() }
            _ = try? wine.shutdown()
            return LaunchOutcome(game: game, exitCode: 0, logURL: nil, diagnoses: [])
        }

        try? store.update(id: game.id) { $0.lastPlayedAt = Date() }

        let diagnoses = LogClassifier(recipe: recipe)
            .classify(log: result.combinedOutput, exitCode: result.exitCode)

        let logURL = try? writeLog(result.combinedOutput, bottle: bottle)
        return LaunchOutcome(game: game, exitCode: result.exitCode,
                             logURL: logURL, diagnoses: diagnoses)
    }

    private func writeLog(_ contents: String, bottle: Bottle) throws -> URL {
        try AppPaths.ensureDirectories()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = AppPaths.logsDirectory.appendingPathComponent("\(bottle.name)-play-\(stamp).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
