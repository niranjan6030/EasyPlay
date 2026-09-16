import Foundation

public enum InstallError: LocalizedError {
    case installerFailed(log: String, diagnoses: [Diagnosis])
    case executableNotFound(glob: String)
    case unsupportedGame(Recipe)
    case steamSignInRequired
    case unsupportedArchive(String)
    case noExecutableInGame(folder: String)

    public var errorDescription: String? {
        switch self {
        case .installerFailed(_, let diagnoses):
            return diagnoses.first?.explanation ?? "The installer didn't finish."
        case .executableNotFound(let glob):
            return "The install finished, but EasyPlay couldn't find the game's program file (expected something matching \(glob))."
        case .unsupportedGame(let recipe):
            return recipe.compatibility.unsupportedReason?.explanation
                ?? "\(recipe.title) can't run on a Mac."
        case .unsupportedArchive(let kind):
            return "EasyPlay can add games from a .zip file or a folder, but not from a .\(kind) file. Open it with The Unarchiver (free on the App Store) first, then add the folder it creates."
        case .noExecutableInGame(let folder):
            return "\(folder) doesn't contain a Windows program (.exe), so there's nothing to play. Check it's the Windows version of the game."
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
                .filter { $0.id != "unknown-failure" }

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

    /// Whether a file or folder is something to *copy in*, rather than an
    /// installer to run. Most free games ship as a zip or a plain folder, and
    /// running a zip through Wine as if it were an installer fails confusingly.
    public static func isImportable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        return ["zip", "7z", "rar"].contains(url.pathExtension.lowercased())
    }

    /// A game unpacked and inspected, but not yet placed in a bottle.
    ///
    /// Which engine a game needs depends on whether it is 32- or 64-bit, and
    /// that can only be read from the program itself — so a zip is unpacked and
    /// examined *before* its bottle is created.
    public struct PreparedGame {
        public let folder: URL
        public let executable: URL
        public let architecture: WindowsExecutable.Architecture
        public let title: String
        public let alternatives: [String]
        let isTemporary: Bool
    }

    /// Unpacks a zip (or reads a folder) and works out what the game is.
    public func prepare(source: URL,
                        title: String? = nil,
                        recipe: Recipe? = nil,
                        executableName: String? = nil,
                        onProgress: ProgressHandler? = nil) throws -> PreparedGame {
        let ext = source.pathExtension.lowercased()
        if ext == "7z" || ext == "rar" { throw InstallError.unsupportedArchive(ext) }

        let fileManager = FileManager.default
        let gameTitle = title ?? recipe?.title ?? source.deletingPathExtension().lastPathComponent
        let folder: URL
        var temporary = false

        if ext == "zip" {
            onProgress?("Unpacking \(source.lastPathComponent)…")
            folder = fileManager.temporaryDirectory
                .appendingPathComponent("easyplay-import-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try runner.runChecked("/usr/bin/ditto", ["-x", "-k", source.path, folder.path], timeout: 1800)
            temporary = true
        } else {
            folder = source
        }

        let finder = ExecutableFinder()
        let programs = finder.executables(in: folder)
        guard !programs.isEmpty else {
            if temporary { try? fileManager.removeItem(at: folder) }
            throw InstallError.noExecutableInGame(folder: source.lastPathComponent)
        }

        let chosen: URL
        if let executableName {
            guard let match = programs.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(executableName) == .orderedSame
                    || $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(executableName) == .orderedSame
            }) else {
                if temporary { try? fileManager.removeItem(at: folder) }
                throw InstallError.executableNotFound(glob: executableName)
            }
            chosen = match
        } else {
            chosen = programs[0]
        }

        let architecture = WindowsExecutable.architecture(of: chosen)
        onProgress?("\(chosen.lastPathComponent) is a \(architecture.displayName) program.")
        return PreparedGame(folder: folder, executable: chosen, architecture: architecture,
                            title: gameTitle,
                            alternatives: programs.filter { $0 != chosen }.map(\.lastPathComponent),
                            isTemporary: temporary)
    }

    /// Moves a prepared game into its bottle and adds it to the library.
    @discardableResult
    public func importPrepared(_ prepared: PreparedGame,
                               into bottle: Bottle,
                               recipe: Recipe?,
                               onProgress: ProgressHandler? = nil) throws -> InstalledGame {
        let fileManager = FileManager.default
        let folderName = prepared.title.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        let destination = bottle.driveC
            .appendingPathComponent("Games", isDirectory: true)
            .appendingPathComponent(folderName.isEmpty ? "Game" : folderName, isDirectory: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        onProgress?("Adding \(prepared.title) to its bottle…")
        if prepared.isTemporary {
            try fileManager.moveItem(at: prepared.folder, to: destination)
        } else {
            let cloned = try runner.run("/bin/cp", ["-cR", prepared.folder.path, destination.path], timeout: 1800)
            if !cloned.succeeded {
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: prepared.folder, to: destination)
            }
        }

        // Built from path components, not string replacement: a temporary folder
        // reported as /var/… resolves to /private/var/…, and replacing one
        // inside the other produced a mangled path that no file matched.
        let relative = Self.relativePath(of: prepared.executable, movedFrom: prepared.folder,
                                         to: destination, in: bottle)
        if !prepared.alternatives.isEmpty {
            onProgress?("Using \(prepared.executable.lastPathComponent) (also found: \(prepared.alternatives.prefix(4).joined(separator: ", ")))")
        }

        let game = InstalledGame(
            title: prepared.title,
            bottleID: bottle.id,
            recipeID: recipe?.id,
            executableRelativePath: relative,
            compatibilityRating: recipe?.compatibility.rating ?? .untested
        )
        try store.add(game)
        onProgress?("\(prepared.title) is ready to play.")
        return game
    }

    /// Where a file ends up, in bottle-relative form, after its folder is moved.
    public static func relativePath(of file: URL, movedFrom folder: URL, to destination: URL, in bottle: Bottle) -> String {
        let fileParts = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let folderParts = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents

        // /var/… and /private/var/… name the same place, and only one of them
        // resolves when the path doesn't exist yet — so fall back to matching on
        // the folder's own name rather than assuming a clean prefix.
        let inside: [String]
        if fileParts.starts(with: folderParts) {
            inside = Array(fileParts.dropFirst(folderParts.count))
        } else if let name = folderParts.last,
                  let index = fileParts.lastIndex(of: name) {
            inside = Array(fileParts.dropFirst(index + 1))
        } else {
            inside = [file.lastPathComponent]
        }
        let placed = inside.reduce(destination) { $0.appendingPathComponent($1) }

        let placedParts = placed.standardizedFileURL.pathComponents
        let bottleParts = bottle.url.standardizedFileURL.pathComponents
        return Array(placedParts.dropFirst(min(bottleParts.count, placedParts.count)))
            .joined(separator: "/")
    }

    /// Everything EasyPlay will accept as "a game to install": an installer to
    /// run, an archive to unpack, or a folder holding the game already.
    public static func canInstall(_ url: URL) -> Bool {
        if isImportable(url) { return true }
        return ["exe", "msi", "iso"].contains(url.pathExtension.lowercased())
    }

    /// Adds a game that comes as a zip file or a folder — no installer.
    ///
    /// The files are copied into the bottle, then the game's program is picked:
    /// the one named by `executableName` if given, else the preset's glob, else
    /// the largest program that isn't a settings tool or uninstaller.
    @discardableResult
    public func importGame(from source: URL,
                           into bottle: Bottle,
                           recipe: Recipe?,
                           title: String? = nil,
                           executableName: String? = nil,
                           onProgress: ProgressHandler? = nil) throws -> InstalledGame {
        if let recipe, recipe.compatibility.rating == .notSupported {
            throw InstallError.unsupportedGame(recipe)
        }
        let ext = source.pathExtension.lowercased()
        if ext == "7z" || ext == "rar" { throw InstallError.unsupportedArchive(ext) }

        let fileManager = FileManager.default
        let baseName = source.deletingPathExtension().lastPathComponent
        let gameTitle = title ?? recipe?.title ?? baseName
        let folderName = gameTitle.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        let destination = bottle.driveC
            .appendingPathComponent("Games", isDirectory: true)
            .appendingPathComponent(folderName.isEmpty ? "Game" : folderName, isDirectory: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if ext == "zip" {
            onProgress?("Unpacking \(source.lastPathComponent)…")
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            // ditto keeps permissions and handles the zips macOS itself makes.
            try runner.runChecked("/usr/bin/ditto", ["-x", "-k", source.path, destination.path], timeout: 1800)
        } else {
            onProgress?("Copying \(source.lastPathComponent)…")
            // An APFS clone where possible: instant, and no extra disk.
            let cloned = try runner.run("/bin/cp", ["-cR", source.path, destination.path], timeout: 1800)
            if !cloned.succeeded {
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
            }
        }

        let finder = ExecutableFinder()
        let programs = finder.executables(in: destination)
        guard !programs.isEmpty else {
            try? fileManager.removeItem(at: destination)
            throw InstallError.noExecutableInGame(folder: source.lastPathComponent)
        }

        let chosen: URL
        if let executableName {
            guard let match = programs.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(executableName) == .orderedSame
                    || $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(executableName) == .orderedSame
            }) else {
                throw InstallError.executableNotFound(glob: executableName)
            }
            chosen = match
        } else if let recipe, let match = finder.find(glob: recipe.launch.executableGlob, in: bottle,
                                                       skippingSupportFiles: false),
                  match.path.hasPrefix(destination.path) {
            chosen = match
        } else {
            chosen = programs[0]
        }

        if programs.count > 1 {
            let others = programs.filter { $0 != chosen }.map(\.lastPathComponent).prefix(4)
            onProgress?("Using \(chosen.lastPathComponent) (also found: \(others.joined(separator: ", ")))")
        }

        let game = InstalledGame(
            title: gameTitle,
            bottleID: bottle.id,
            recipeID: recipe?.id,
            executableRelativePath: chosen.path.replacingOccurrences(of: bottle.url.path + "/", with: ""),
            compatibilityRating: recipe?.compatibility.rating ?? .untested
        )
        try store.add(game)
        onProgress?("\(gameTitle) is ready to play.")
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
        // The preset names this program on purpose, so it is looked for even
        // where the install-time guessing heuristics would skip it.
        guard let executable = ExecutableFinder().find(glob: recipe.launch.executableGlob, in: bottle,
                                                       skippingSupportFiles: false) else {
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
