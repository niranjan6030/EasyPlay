import Foundation
import EasyPlayKit

enum RecipeLibraryTests {
    /// A user directory that does not exist, so only shipped presets are seen.
    private static var library: RecipeLibrary {
        RecipeLibrary(userDirectory: URL(fileURLWithPath: "/nonexistent-easyplay-test"))
    }

    static func run() throws {
        Harness.suite("Recipe library") {
            Harness.expect(library.loadErrors.isEmpty,
                           "every shipped preset parses: \(library.loadErrors)")
            Harness.expect(!library.all.isEmpty, "presets are found in the app bundle")

            do {
                let ride4 = try library.recipe(id: "ride-4")
                Harness.expect(ride4.compatibility.rating == .runsGreat, "RIDE 4 is rated Runs Great")
                Harness.expect(ride4.graphics.backend == .d3dMetal, "RIDE 4 uses D3DMetal")
                Harness.expect(ride4.install.kind == .steam, "RIDE 4 installs through Steam")
                // 1024650 is Port Royale 4 — an easy and expensive ID to get wrong.
                Harness.expectEqual(ride4.install.steamAppID, "1259980", "RIDE 4's Steam app ID is correct")
                Harness.expect(ride4.requires.rosetta, "RIDE 4 requires Rosetta")
                Harness.expect(!ride4.knownIssues.isEmpty,
                               "the reference preset demonstrates error handling")

                let valorant = try library.recipe(id: "valorant")
                Harness.expect(valorant.compatibility.rating == .notSupported, "VALORANT is refused")
                Harness.expect(valorant.compatibility.unsupportedReason == .kernelAntiCheat,
                               "and the refusal carries a reason rather than just failing")
                Harness.expect(!valorant.compatibility.rating.isPlayable, "unsupported games are not playable")

                let data = try JSONEncoder().encode(ride4)
                Harness.expect(try JSONDecoder().decode(Recipe.self, from: data) == ride4,
                               "a recipe survives a round trip through JSON")
            } catch {
                Harness.expect(false, "shipped presets load: \(error)")
            }

            Harness.expectEqual(library.matchRecipe(forInstallerNamed: "RIDE_4_setup.exe")?.id, "ride-4",
                                "an installer filename is matched to its preset")
            // Real installers are named after their archive, not their product,
            // so a preset can declare aliases for its own installer filenames.
            Harness.expectEqual(library.matchRecipe(forInstallerNamed: "7z2409-x64.exe")?.id, "7-zip",
                                "a preset's declared installer aliases are matched")
            Harness.expect(library.matchRecipe(forInstallerNamed: "SomeUnknownGame.exe") == nil,
                           "an unknown installer matches nothing rather than guessing")

            for recipe in library.all {
                Harness.expect(recipe.schemaVersion <= RecipeLibrary.currentSchemaVersion,
                               "\(recipe.id) targets a schema this build understands")
            }
        }
    }
}
