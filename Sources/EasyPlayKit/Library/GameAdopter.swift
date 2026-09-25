import Foundation

/// Puts a game that is already installed in a bottle back into the library.
///
/// A bottle holds the game; the library holds the entry that makes it appear in
/// the app and gives it a Play button. Those can drift apart — a library entry
/// pruned while its bottle survived, an install interrupted after the files
/// landed but before the entry was written — and when they do, the game is
/// perfectly installed and completely unreachable.
///
/// Rather than ask the user to reinstall a game that is sitting right there,
/// EasyPlay looks in the bottle and adopts what it finds.
public struct GameAdopter {
    public typealias ProgressHandler = (String) -> Void

    /// What was found in a bottle, before anything is written.
    public struct Candidate {
        public let bottle: Bottle
        public let executable: URL
        public let relativePath: String
        public let title: String
        public let recipe: Recipe?
        /// Other programs in the bottle, for when the pick is wrong.
        public let alternatives: [String]
    }

    private let finder: ExecutableFinder
    private let store: GameStore
    private let recipes: RecipeLibrary

    public init(finder: ExecutableFinder = ExecutableFinder(),
                store: GameStore = GameStore(),
                recipes: RecipeLibrary = RecipeLibrary()) {
        self.finder = finder
        self.store = store
        self.recipes = recipes
    }

    /// Bottles holding no game the library knows about.
    public func unregisteredBottles(from bottles: [Bottle]) -> [Bottle] {
        let known = Set(store.load().map(\.bottleID))
        return bottles.filter { !known.contains($0.id) }
    }

    /// Looks for the game inside a bottle without changing anything.
    ///
    /// A preset's own glob wins when the bottle was built from one, since it
    /// names the program the preset's author verified. Otherwise the largest
    /// executable is the best guess available: launchers and crash handlers are
    /// small, and the game itself rarely is.
    public func candidate(in bottle: Bottle, executableName: String? = nil) throws -> Candidate {
        let recipe = bottle.recipeID.flatMap { try? recipes.recipe(id: $0) }

        var executable: URL?
        if let executableName {
            executable = finder.find(glob: "**/\(executableName)", in: bottle, skippingSupportFiles: false)
        }
        if executable == nil, let glob = recipe?.launch.executableGlob {
            executable = finder.find(glob: glob, in: bottle)
        }

        let everything = finder.candidates(glob: "**/*.exe", in: bottle)
            .sorted { sizeOf($0) > sizeOf($1) }
        if executable == nil {
            executable = everything.first
        }

        guard let executable else {
            throw InstallError.noExecutableInGame(folder: bottle.name)
        }

        let relative = executable.path
            .replacingOccurrences(of: bottle.url.path + "/", with: "")
        let title = recipe?.title ?? executable.deletingPathExtension().lastPathComponent

        return Candidate(
            bottle: bottle,
            executable: executable,
            relativePath: relative,
            title: title,
            recipe: recipe,
            alternatives: everything
                .filter { $0 != executable }
                .prefix(5)
                .map(\.lastPathComponent))
    }

    /// Writes the library entry. Returns the game as the library now holds it.
    ///
    /// `titled` renames it on the way in, for when the executable's name isn't
    /// the name anyone calls the game.
    @discardableResult
    public func adopt(_ candidate: Candidate, titled title: String? = nil,
                      onProgress: ProgressHandler? = nil) throws -> InstalledGame {
        let game = InstalledGame(
            title: title ?? candidate.title,
            bottleID: candidate.bottle.id,
            recipeID: candidate.recipe?.id,
            executableRelativePath: candidate.relativePath,
            compatibilityRating: candidate.recipe?.compatibility.rating ?? .untested
        )
        try store.add(game)
        onProgress?("Added \(game.title) to your library.")
        return game
    }

    private func sizeOf(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
    }
}
