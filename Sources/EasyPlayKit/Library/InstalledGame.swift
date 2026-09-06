import Foundation

/// A game the user has installed, as the library view sees it.
public struct InstalledGame: Codable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var bottleID: String
    public var recipeID: String?
    /// Path to the game's executable, relative to the bottle directory, so the
    /// entry survives the support folder being moved.
    public var executableRelativePath: String
    public var installedAt: Date
    public var lastPlayedAt: Date?
    /// Rating carried over from the recipe at install time, so the library can
    /// show a badge without reloading every preset.
    public var compatibilityRating: CompatibilityRating

    public init(id: String = UUID().uuidString,
                title: String,
                bottleID: String,
                recipeID: String?,
                executableRelativePath: String,
                installedAt: Date = Date(),
                lastPlayedAt: Date? = nil,
                compatibilityRating: CompatibilityRating) {
        self.id = id
        self.title = title
        self.bottleID = bottleID
        self.recipeID = recipeID
        self.executableRelativePath = executableRelativePath
        self.installedAt = installedAt
        self.lastPlayedAt = lastPlayedAt
        self.compatibilityRating = compatibilityRating
    }

    public func executableURL(in bottle: Bottle) -> URL {
        bottle.url.appendingPathComponent(executableRelativePath)
    }

    /// The rating to show now.
    ///
    /// `compatibilityRating` is a snapshot taken at install time, which goes
    /// stale as soon as its preset is updated — a preset promoted from untested
    /// to verified should be reflected in the library immediately. The live
    /// preset therefore wins, and the snapshot remains the fallback for games
    /// whose preset has since been removed.
    public func currentRating(from recipe: Recipe?) -> CompatibilityRating {
        recipe?.compatibility.rating ?? compatibilityRating
    }
}

/// The installed-games list, persisted as one JSON file.
public struct GameStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = AppPaths.libraryFile, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() -> [InstalledGame] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([InstalledGame].self, from: data)) ?? []
    }

    public func save(_ games: [InstalledGame]) throws {
        try AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(games).write(to: fileURL, options: .atomic)
    }

    public func add(_ game: InstalledGame) throws {
        var games = load().filter { $0.id != game.id }
        games.append(game)
        try save(games)
    }

    public func remove(id: String) throws {
        try save(load().filter { $0.id != id })
    }

    /// Drops entries whose bottle no longer exists.
    ///
    /// Cascading on delete covers EasyPlay's own deletions, but a bottle can also
    /// vanish because someone dragged it to the Trash. The library heals itself
    /// on load rather than showing games that cannot possibly launch.
    @discardableResult
    public func pruneOrphans(knownBottleIDs: Set<String>) -> [InstalledGame] {
        let games = load()
        let surviving = games.filter { knownBottleIDs.contains($0.bottleID) }
        if surviving.count != games.count {
            try? save(surviving)
        }
        return surviving
    }

    public func update(id: String, transform: (inout InstalledGame) -> Void) throws {
        var games = load()
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        transform(&games[index])
        try save(games)
    }
}
