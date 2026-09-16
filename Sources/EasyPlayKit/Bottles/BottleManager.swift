import Foundation

public enum BottleError: LocalizedError {
    case noBackendAvailable
    case alreadyExists(String)
    case notFound(String)
    case initialisationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noBackendAvailable:
            return "No Wine engine is installed, so EasyPlay can't create a bottle yet."
        case .alreadyExists(let name):
            return "A bottle called '\(name)' already exists."
        case .notFound(let id):
            return "No bottle with ID '\(id)'."
        case .initialisationFailed(let detail):
            return "Setting up the bottle failed: \(detail)"
        }
    }
}

/// Creates, configures, lists and deletes bottles.
public struct BottleManager {
    /// Progress messages fit for showing a user, not raw Wine output.
    public typealias ProgressHandler = (String) -> Void

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

    // MARK: - Listing

    public func list() -> [Bottle] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: AppPaths.bottlesDirectory, includingPropertiesForKeys: nil) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return entries.compactMap { directory -> Bottle? in
            let metadata = directory.appendingPathComponent("easyplay-bottle.json")
            guard let data = try? Data(contentsOf: metadata) else { return nil }
            return try? decoder.decode(Bottle.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func bottle(id: String) throws -> Bottle {
        guard let bottle = list().first(where: { $0.id == id }) else {
            throw BottleError.notFound(id)
        }
        return bottle
    }

    // MARK: - Creation

    /// A freshly booted, untouched Windows environment for this engine. New
    /// bottles are APFS clones of it: a clone takes well under a second and no
    /// extra disk until something changes, where booting a fresh environment
    /// took 20-60 seconds every time. Keyed by engine version, so upgrading the
    /// engine builds a new template instead of reusing a stale one.
    var templateURL: URL {
        let version = backend.version.filter { $0.isLetter || $0.isNumber || $0 == "." }
        return AppPaths.runtimesDirectory
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent("\(backend.kind.rawValue)-\(version)", isDirectory: true)
    }

    private func ensureTemplate(onProgress: ProgressHandler?) throws {
        let ready = templateURL.appendingPathComponent(".easyplay-template-ready")
        if fileManager.fileExists(atPath: ready.path) { return }

        onProgress?("Preparing a Windows environment (first time only)…")
        try? fileManager.removeItem(at: templateURL)
        try fileManager.createDirectory(at: templateURL, withIntermediateDirectories: true)

        let template = Bottle(id: templateURL.lastPathComponent, name: "template", backendKind: backend.kind)
        var environment = WineRunner(backend: backend, bottle: template, runner: runner).environment()
        environment["WINEPREFIX"] = templateURL.path
        _ = try runner.run(backend.wineExecutable.path, ["wineboot", "--init"], environment: environment, timeout: 600)
        _ = try runner.run(backend.wineserver.path, ["-w"],
                           environment: ["WINEPREFIX": templateURL.path], timeout: 120)

        guard fileManager.fileExists(atPath: templateURL.appendingPathComponent("drive_c/windows").path) else {
            try? fileManager.removeItem(at: templateURL)
            throw BottleError.initialisationFailed("Wine couldn't create a Windows environment.")
        }
        fileManager.createFile(atPath: ready.path, contents: nil)
    }

    /// Copies the template into place, as an APFS clone where the disk allows.
    private func cloneTemplate(to destination: URL) throws {
        // cp -c requests a clone; on a filesystem without clones it fails and an
        // ordinary copy is made instead.
        let cloned = try runner.run("/bin/cp", ["-cR", templateURL.path, destination.path], timeout: 600)
        if !cloned.succeeded {
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: templateURL, to: destination)
        }
        try? fileManager.removeItem(at: destination.appendingPathComponent(".easyplay-template-ready"))
    }

    public func bottle(named name: String) -> Bottle? {
        list().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Returns the bottle already made for this game, or creates one.
    ///
    /// Retrying an install is the normal response to a failure, and it used to
    /// fail again immediately with "a bottle with that name already exists".
    /// `created` tells the caller whether it may clean the bottle up after a
    /// failure — a bottle that already held the user's files must never be
    /// deleted because a retry didn't work out.
    public func createOrReuse(name: String, recipe: Recipe?,
                              onProgress: ProgressHandler? = nil) throws -> (bottle: Bottle, created: Bool) {
        if var existing = bottle(named: name) {
            onProgress?("Using the existing \(existing.name) bottle.")
            if let recipe { try apply(recipe, to: &existing, onProgress: onProgress) }
            return (existing, false)
        }
        return (try create(name: name, recipe: recipe, onProgress: onProgress), true)
    }

    /// Creates a bottle and applies a recipe to it.
    public func create(name: String,
                       recipe: Recipe? = nil,
                       onProgress: ProgressHandler? = nil) throws -> Bottle {
        if list().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw BottleError.alreadyExists(name)
        }

        try AppPaths.ensureDirectories()

        var bottle = Bottle(
            name: name,
            recipeID: recipe?.id,
            windowsVersion: recipe?.bottle.windowsVersion ?? "win10",
            architecture: recipe?.bottle.architecture ?? "win64",
            graphicsBackend: recipe?.graphics.backend ?? backend.builtinTranslator,
            backendKind: backend.kind
        )

        try ensureTemplate(onProgress: onProgress)
        onProgress?("Creating a fresh Windows environment…")
        try cloneTemplate(to: bottle.url)

        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)
        if let recipe {
            try apply(recipe, to: &bottle, using: wine, onProgress: onProgress)
        } else {
            onProgress?("Applying default settings…")
            var patch = RegistryPatch()
            patch.set(#"HKEY_CURRENT_USER\Software\Wine"#, "Version", bottle.windowsVersion)
            try wine.apply(patch)
        }

        try save(bottle)
        onProgress?("Bottle ready.")
        return bottle
    }

    /// Applies a recipe to an existing bottle. Split out from `create` so a
    /// preset can be re-applied after it is updated, without a reinstall.
    public func apply(_ recipe: Recipe,
                      to bottle: inout Bottle,
                      using wine: WineRunner? = nil,
                      onProgress: ProgressHandler? = nil) throws {
        let wine = wine ?? WineRunner(backend: backend, bottle: bottle, runner: runner)

        onProgress?("Applying the \(recipe.title) settings…")
        try wine.apply(RegistryPatch.forRecipe(recipe))

        for verb in recipe.winetricks {
            onProgress?("Installing \(verb) (this can take a few minutes)…")
            try runWinetricks(verb, bottle: bottle)
        }

        bottle.recipeID = recipe.id
        bottle.windowsVersion = recipe.bottle.windowsVersion
        bottle.graphicsBackend = recipe.graphics.backend
        try save(bottle)
    }

    /// Adds a Windows runtime to an existing bottle — the automated form of the
    /// fixes the diagnostics suggest.
    public func applyWinetricksVerb(_ verb: String, to bottle: Bottle) throws {
        try runWinetricks(verb, bottle: bottle)
    }

    /// Changes which DirectX translator a bottle uses, and records the change.
    public func setGraphics(_ graphics: GraphicsBackend, on bottle: inout Bottle) throws {
        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)
        var patch = RegistryPatch()
        for (dll, value) in wine.graphicsOverrides(for: graphics).sorted(by: { $0.key < $1.key }) {
            patch.set(#"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#, dll, value)
        }
        try wine.apply(patch)
        bottle.graphicsBackend = graphics
        try save(bottle)
    }

    private func runWinetricks(_ verb: String, bottle: Bottle) throws {
        guard ProcessRunner.locate("winetricks") != nil else {
            throw BottleError.initialisationFailed("Winetricks isn't installed, so '\(verb)' can't be added.")
        }
        try runner.runChecked(
            "winetricks", ["-q", verb],
            environment: [
                "WINEPREFIX": bottle.url.path,
                "WINE": backend.wineExecutable.path,
                "WINESERVER": backend.wineserver.path,
            ],
            timeout: 1800
        )
    }

    // MARK: - Deletion

    /// Deletes a bottle, everything installed inside it, and the library entries
    /// that pointed at it.
    ///
    /// Wine's background server holds the prefix open, so it is stopped first —
    /// deleting underneath a live `wineserver` leaves stale processes behind.
    ///
    /// Removing the orphaned library entries is done here rather than in the UI:
    /// a game whose bottle no longer exists is not a display concern, and a
    /// front-end that forgot to clean up would leave the library pointing at
    /// nothing.
    public func delete(_ bottle: Bottle, store: GameStore = GameStore()) throws {
        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)
        _ = try? wine.shutdown()

        for game in store.load() where game.bottleID == bottle.id {
            try store.remove(id: game.id)
        }

        guard fileManager.fileExists(atPath: bottle.url.path) else { return }
        try fileManager.removeItem(at: bottle.url)
    }

    // MARK: - Persistence

    public func save(_ bottle: Bottle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try fileManager.createDirectory(at: bottle.url, withIntermediateDirectories: true)
        try encoder.encode(bottle).write(to: bottle.metadataURL, options: .atomic)
    }
}
