import Foundation
import EasyPlayKit

/// The environment handed to Wine is where per-game configuration actually takes
/// effect, and it is invisible when wrong — the game just misbehaves. These check
/// the parts that are easy to get subtly wrong.
enum WineEnvironmentTests {

    private static func backend(_ kind: WineBackend.Kind = .gamePortingToolkit) -> WineBackend {
        WineBackend(
            kind: kind,
            binDirectory: URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin"),
            version: "7.7",
            bundledTranslators: [.d3dMetal, .wineD3D]
        )
    }

    private static func runner(_ kind: WineBackend.Kind = .gamePortingToolkit) -> WineRunner {
        WineRunner(backend: backend(kind), bottle: Bottle(name: "Test", graphicsBackend: .d3dMetal))
    }

    static func run() throws {
        Harness.suite("Wine environment") {
            // Groups are sorted by load order and DLLs sorted within a group, so
            // the string is stable and diffable.
            Harness.expectEqual(
                WineRunner.formatDLLOverrides(["d3d11": "builtin", "dxgi": "builtin", "nvapi": "disabled"]),
                "d3d11,dxgi=builtin;nvapi=disabled",
                "DLLs sharing a load order are grouped")

            Harness.expectEqual(WineRunner.formatDLLOverrides([:]), "",
                                "no overrides produces an empty string")

            // On Game Porting Toolkit the built-in d3d11/dxgi *are* D3DMetal, so
            // choosing D3DMetal must not ask for native DLLs.
            Harness.expectEqual(runner().graphicsOverrides(for: .d3dMetal)["d3d11"], "builtin",
                                "D3DMetal prefers built-in DLLs")

            // DXVK ships its own PE DLLs into the bottle, which Wine loads only
            // when native is preferred.
            Harness.expectEqual(runner().graphicsOverrides(for: .dxvk)["d3d11"], "native",
                                "DXVK prefers native DLLs")

            let bottle = Bottle(name: "RIDE 4")
            let environment = WineRunner(backend: backend(), bottle: bottle).environment()
            Harness.expectEqual(environment["WINEPREFIX"], bottle.url.path,
                                "the prefix points at this bottle")
            Harness.expectEqual(environment["WINEARCH"], "win64", "architecture is set")

            // Without this, D3DMetal's DLLs load but find no framework behind
            // them, and the game fails with an opaque device-creation error.
            let loaderPath = runner().environment()["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
            Harness.expect(loaderPath.contains("lib/external"),
                           "D3DMetal's directory is on the dynamic loader path")
            Harness.expect(loaderPath.contains("/usr/lib"),
                           "/usr/lib is kept — dropping it breaks every system library")

            // Classic Wine links against libraries in a Frameworks folder beside
            // it; without them it dies before the game's first frame.
            let classic = WineBackend(
                kind: .classicWine,
                binDirectory: URL(fileURLWithPath: "/Engines/Classic Wine/wswine.bundle/bin"),
                version: "8.0.1", bundledTranslators: [.wineD3D])
            let classicPath = (WineRunner(backend: classic, bottle: Bottle(name: "Old"))
                .environment()["DYLD_FALLBACK_LIBRARY_PATH"] ?? "").split(separator: ":").map(String.init)
            Harness.expectEqual(classicPath, [
                "/Engines/Classic Wine/Frameworks",
                "/Engines/Classic Wine/Frameworks/GStreamer.framework/Versions/1.0/lib",
                "/Engines/Classic Wine/wswine.bundle/lib",
                "/usr/lib",
            ], "Classic Wine's own libraries are on the loader path, in order")

            // wineserver needs the engine's libraries too. When it didn't get
            // them, "stop the game" started a server that couldn't run, reported
            // success, and left the game running.
            Harness.expectEqual(
                WineRunner(backend: classic, bottle: Bottle(name: "Old")).serverEnvironment()["DYLD_FALLBACK_LIBRARY_PATH"],
                classicPath.joined(separator: ":"),
                "wineserver is given the same loader path as wine")

            // Measured: 32-bit games crash on GPTK's Wine 7.7, and TrackMania
            // crashes on Wine 11.17 but runs on Wine 8.
            let gptk = backend()
            let staging = WineBackend(kind: .wineStaging, binDirectory: URL(fileURLWithPath: "/S/bin"),
                                      version: "11.17", bundledTranslators: [.wineD3D])
            func report(_ engines: [WineBackend]) -> EnvironmentReport {
                EnvironmentReport(system: SystemProbe().probe(), homebrewVersion: nil, backends: engines,
                                  preferredBackend: engines.first, winetricksPath: nil, checks: [])
            }
            let all = report([gptk, staging, classic])
            Harness.expectEqual(all.backend(for: nil, architecture: .x86)?.kind, .classicWine,
                                "32-bit games go to Classic Wine when it is installed")
            Harness.expectEqual(report([gptk, staging]).backend(for: nil, architecture: .x86)?.kind, .wineStaging,
                                "without it, 32-bit games fall back to Wine Staging")
            Harness.expectEqual(all.backend(for: nil, architecture: .x64)?.kind, .gamePortingToolkit,
                                "64-bit games stay on the Game Porting Toolkit")

            // Wine can upgrade an older prefix but not open a newer one.
            Harness.expect(WineBackend.Kind.gamePortingToolkit.generation < WineBackend.Kind.classicWine.generation
                           && WineBackend.Kind.classicWine.generation < WineBackend.Kind.wineStaging.generation,
                           "engines are ordered 7.7 < 8 < 11, so bottles only move forward")

            Harness.expect(runner(.wineHQ).environment()["DYLD_FALLBACK_LIBRARY_PATH"] == nil,
                           "non-GPTK backends get no loader-path injection")

            // Wine's debug channels are expensive; leaving them on costs frame rate.
            Harness.expectEqual(runner().environment(verbosity: .play)["WINEDEBUG"], "-all",
                                "play mode turns Wine's debug output off")
            Harness.expect(runner().environment(verbosity: .diagnostic)["WINEDEBUG"] != "-all",
                           "diagnostic mode keeps errors for the classifier")

            if let recipe = try? RecipeLibrary().recipe(id: "ride-4") {
                let merged = runner().environment(recipe: recipe)
                Harness.expectEqual(merged["WINEESYNC"], "1", "recipe environment is merged in")
                Harness.expectEqual(merged["ROSETTA_ADVERTISE_AVX"], "1",
                                    "AVX is advertised to Rosetta for game code that needs it")
            }
        }
    }
}
