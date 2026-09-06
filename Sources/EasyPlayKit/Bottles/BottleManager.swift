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

    /// Creates a bottle and applies a recipe to it.
    ///
    /// Wine's own `wineboot --init` does the heavy lifting; everything after it
    /// is the per-game configuration a user would otherwise apply by hand in
    /// `winecfg` and `regedit`.
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

        try fileManager.createDirectory(at: bottle.url, withIntermediateDirectories: true)

        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)

        onProgress?("Creating a fresh Windows environment…")
        // First boot lays down the fake C: drive, registry and system DLLs. It is
        // slow (tens of seconds) and Wine reports progress only on stderr.
        let boot = try wine.run(["wineboot", "--init"], verbosity: .diagnostic, timeout: 600)
        guard boot.succeeded || bottle.exists else {
            try? fileManager.removeItem(at: bottle.url)
            throw BottleError.initialisationFailed(boot.combinedOutput.suffix(400).description)
        }

        if let recipe {
            try apply(recipe, to: &bottle, using: wine, onProgress: onProgress)
        } else {
            onProgress?("Applying default settings…")
            try wine.setRegistryValue(key: #"HKCU\Software\Wine"#, name: "Version", value: bottle.windowsVersion)
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

        onProgress?("Telling Windows programs this is \(recipe.bottle.windowsVersion)…")
        try wine.setRegistryValue(key: #"HKCU\Software\Wine"#,
                                  name: "Version", value: recipe.bottle.windowsVersion)

        if recipe.bottle.retinaMode {
            onProgress?("Turning on Retina display support…")
            try wine.setRegistryValue(key: #"HKCU\Software\Wine\Mac Driver"#,
                                      name: "RetinaMode", value: "y")
        }

        // Overrides are written into the registry as well as passed through the
        // environment: the environment covers processes EasyPlay launches, the
        // registry covers anything the game launches for itself.
        if !recipe.dllOverrides.isEmpty {
            onProgress?("Configuring graphics libraries…")
            for (dll, value) in recipe.dllOverrides.sorted(by: { $0.key < $1.key }) {
                try wine.setRegistryValue(key: #"HKCU\Software\Wine\DllOverrides"#,
                                          name: dll, value: value)
            }
        }

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
        for (dll, value) in wine.graphicsOverrides(for: graphics).sorted(by: { $0.key < $1.key }) {
            try wine.setRegistryValue(key: #"HKCU\Software\Wine\DllOverrides"#, name: dll, value: value)
        }
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
                "WINE": backend.wine64.path,
                "WINESERVER": backend.wineserver.path,
            ],
            timeout: 1800
        )
    }

    // MARK: - Deletion

    /// Deletes a bottle and everything installed inside it.
    ///
    /// Wine's background server holds the prefix open, so it is stopped first —
    /// deleting underneath a live `wineserver` leaves stale processes behind.
    public func delete(_ bottle: Bottle) throws {
        let wine = WineRunner(backend: backend, bottle: bottle, runner: runner)
        _ = try? wine.shutdown()
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
