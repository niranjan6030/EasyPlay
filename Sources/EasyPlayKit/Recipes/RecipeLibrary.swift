import Foundation

public enum RecipeError: LocalizedError {
    case notFound(String)
    case decodingFailed(file: String, underlying: Error)
    case unsupportedSchema(file: String, version: Int)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "No preset named '\(id)'."
        case .decodingFailed(let file, let underlying):
            return "Preset '\(file)' couldn't be read: \(underlying.localizedDescription)"
        case .unsupportedSchema(let file, let version):
            return "Preset '\(file)' uses schema version \(version), which this version of EasyPlay doesn't understand."
        }
    }
}

/// Loads the shipped presets plus anything the user has added locally.
///
/// v1 is deliberately offline: presets are files on disk, not a service. A user
/// can read them, edit them and share them by sending a file — no account, no
/// backend, nothing to keep running.
public struct RecipeLibrary {
    public static let currentSchemaVersion = 1

    /// Recipes that ship inside the app.
    public private(set) var bundled: [Recipe] = []
    /// Recipes the user dropped into Application Support. These win on ID clashes
    /// so a user can override a shipped preset without editing the app.
    public private(set) var user: [Recipe] = []
    /// Files that failed to load, surfaced rather than silently skipped.
    public private(set) var loadErrors: [Error] = []

    public var all: [Recipe] {
        var byID: [String: Recipe] = [:]
        for recipe in bundled { byID[recipe.id] = recipe }
        for recipe in user { byID[recipe.id] = recipe }
        return byID.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public static var userRecipesDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("Recipes", isDirectory: true)
    }

    /// Where the shipped presets live.
    ///
    /// Inside the assembled `.app` they sit in `Contents/Resources/Recipes`; when
    /// running from a SwiftPM build they are in the generated resource bundle.
    /// The app path is checked first, and `Bundle.module` is only touched as a
    /// fallback — reading it when the bundle is absent traps, so it must never be
    /// the first thing tried.
    public static var bundledRecipesDirectory: URL? {
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("Recipes", isDirectory: true),
           FileManager.default.fileExists(atPath: resources.path) {
            return resources
        }
        return Bundle.module.url(forResource: "Recipes", withExtension: nil)
    }

    public init(recipesDirectory: URL? = nil,
                userDirectory: URL = RecipeLibrary.userRecipesDirectory) {
        bundled = Self.load(from: recipesDirectory ?? Self.bundledRecipesDirectory, errors: &loadErrors)
        user = Self.load(from: userDirectory, errors: &loadErrors)
    }

    public func recipe(id: String) throws -> Recipe {
        guard let recipe = all.first(where: { $0.id == id }) else {
            throw RecipeError.notFound(id)
        }
        return recipe
    }

    /// Best-effort match of a free-form name — what the UI uses when a user drags
    /// in `RIDE4_setup.exe` and we try to recognise the game.
    public func matchRecipe(forInstallerNamed filename: String) -> Recipe? {
        let haystack = filename
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
        guard !haystack.isEmpty else { return nil }

        return all.first { recipe in
            let needles = ([recipe.id, recipe.title] + (recipe.installerPatterns ?? [])).map {
                $0.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
            }
            return needles.contains { !$0.isEmpty && haystack.contains($0) }
        }
    }

    private static func load(from directory: URL?, errors: inout [Error]) -> [Recipe] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil) else { return [] }

        let decoder = JSONDecoder()
        var recipes: [Recipe] = []

        for file in files where file.pathExtension.lowercased() == "json" {
            do {
                let recipe = try decoder.decode(Recipe.self, from: try Data(contentsOf: file))
                guard recipe.schemaVersion <= currentSchemaVersion else {
                    errors.append(RecipeError.unsupportedSchema(
                        file: file.lastPathComponent, version: recipe.schemaVersion))
                    continue
                }
                recipes.append(recipe)
            } catch {
                errors.append(RecipeError.decodingFailed(file: file.lastPathComponent, underlying: error))
            }
        }
        return recipes
    }
}
