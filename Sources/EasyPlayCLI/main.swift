import Foundation
import EasyPlayKit

// A command-line front-end over EasyPlayKit.
//
// The GUI is the product, but every operation is reachable from here too. That
// keeps the engine honest: if a step only works when a SwiftUI view drives it,
// the seam between logic and interface is in the wrong place.

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    easyplay — run Windows games on a Mac, without the Wine homework

    USAGE
      easyplay doctor              Check this Mac and report what's missing
      easyplay recipes             List the game presets EasyPlay knows about
      easyplay recipes <id>        Show one preset in detail

      easyplay bottles             List the bottles on this Mac
      easyplay bottle-create <name> [--recipe <id>]
                                   Create a bottle, optionally from a preset
      easyplay bottle-delete <id>  Delete a bottle and everything in it
      easyplay verify <bottle-id>  Prove a bottle can run a Windows program

      easyplay games               List installed games
      easyplay install <installer.exe> --bottle <id> [--recipe <id>]
                                   Run a Windows installer inside a bottle
      easyplay play <game-id> [--seconds <n>]
                                   Launch an installed game

    """)
}

// MARK: - Output helpers

enum Colour {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let red = "\u{001B}[31m"
}

func symbol(for status: EnvironmentCheck.Status) -> String {
    switch status {
    case .ok: return "\(Colour.green)✔\(Colour.reset)"
    case .warning: return "\(Colour.yellow)!\(Colour.reset)"
    case .blocked: return "\(Colour.red)✘\(Colour.reset)"
    }
}

func badge(for rating: CompatibilityRating) -> String {
    let colour: String
    switch rating {
    case .runsGreat: colour = Colour.green
    case .runsOK: colour = Colour.yellow
    case .untested: colour = Colour.dim
    case .notSupported: colour = Colour.red
    }
    return "\(colour)\(rating.displayName)\(Colour.reset)"
}

// MARK: - Shared

/// Resolves the Wine build to drive, or explains why we can't.
func resolveBackend() -> WineBackend? {
    let report = ToolchainDetector().detect()
    guard let backend = report.preferredBackend else {
        print("\(Colour.red)No Wine engine found. Run 'easyplay doctor' to see how to install one.\(Colour.reset)")
        return nil
    }
    return backend
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

// MARK: - Commands

func doctor() -> Int32 {
    let report = ToolchainDetector().detect()

    print("\n\(Colour.bold)EasyPlay — environment check\(Colour.reset)\n")

    for check in report.checks {
        print(" \(symbol(for: check.status)) \(Colour.bold)\(check.title)\(Colour.reset)")
        print("   \(check.detail)")
        if let remedy = check.remedy {
            print("   \(Colour.yellow)→ \(remedy)\(Colour.reset)")
        }
        if let command = check.remedyCommand {
            command.split(separator: "\n").forEach { print("     \(Colour.dim)\($0)\(Colour.reset)") }
        }
        print("")
    }

    if report.backends.count > 1 {
        print(" \(Colour.dim)Other Wine builds found:\(Colour.reset)")
        report.backends.dropFirst().forEach {
            print("   \(Colour.dim)\($0.displayName) — \($0.binDirectory.path)\(Colour.reset)")
        }
        print("")
    }

    if report.isReady {
        print(" \(Colour.green)Ready to install games.\(Colour.reset)\n")
        return 0
    }
    print(" \(Colour.red)\(report.blockers.count) thing(s) must be fixed first.\(Colour.reset)\n")
    return 1
}

func listRecipes() -> Int32 {
    let library = RecipeLibrary()

    print("\n\(Colour.bold)Presets\(Colour.reset)\n")
    for recipe in library.all {
        let identifier = recipe.id.padding(toLength: max(14, recipe.id.count + 1), withPad: " ", startingAt: 0)
        print("  \(Colour.dim)\(identifier)\(Colour.reset)\(recipe.title)  \(badge(for: recipe.compatibility.rating))")
    }

    for error in library.loadErrors {
        print("\n  \(Colour.red)! \(error.localizedDescription)\(Colour.reset)")
    }
    print("")
    return library.loadErrors.isEmpty ? 0 : 1
}

func showRecipe(_ id: String) -> Int32 {
    do {
        let recipe = try RecipeLibrary().recipe(id: id)

        print("\n\(Colour.bold)\(recipe.title)\(Colour.reset)  \(badge(for: recipe.compatibility.rating))")
        if let publisher = recipe.publisher { print("\(Colour.dim)\(publisher)\(Colour.reset)") }
        print("\n  \(recipe.compatibility.rating.summary)")

        if let reason = recipe.compatibility.unsupportedReason {
            print("\n  \(Colour.red)\(reason.explanation)\(Colour.reset)")
        }
        if let source = recipe.compatibility.source {
            print("\n  \(Colour.dim)Source: \(source)\(Colour.reset)")
        }
        if !recipe.compatibility.notes.isEmpty {
            print("\n  \(Colour.bold)Notes\(Colour.reset)")
            recipe.compatibility.notes.forEach { print("   • \($0)") }
        }

        print("\n  \(Colour.bold)Configuration\(Colour.reset)")
        print("   Windows version   \(recipe.bottle.windowsVersion) (\(recipe.bottle.architecture))")
        print("   Graphics          \(recipe.graphics.backend.displayName)")
        print("   Disk needed       \(recipe.requires.diskGB) GB")
        if !recipe.dllOverrides.isEmpty {
            let overrides = recipe.dllOverrides.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            print("   DLL overrides     \(overrides)")
        }
        if !recipe.environment.isEmpty {
            let environment = recipe.environment.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            print("   Environment       \(environment)")
        }
        if !recipe.winetricks.isEmpty {
            print("   Winetricks        \(recipe.winetricks.joined(separator: ", "))")
        }

        print("\n  \(Colour.bold)Install\(Colour.reset)")
        print("   Method            \(recipe.install.kind.rawValue)")
        if let appID = recipe.install.steamAppID { print("   Steam app ID      \(appID)") }
        recipe.install.hints.forEach { print("   • \($0)") }

        if !recipe.knownIssues.isEmpty {
            print("\n  \(Colour.bold)Known issues this preset can recognise\(Colour.reset)")
            recipe.knownIssues.forEach { print("   • \($0.title) — \($0.fix)") }
        }
        print("")
        return 0
    } catch {
        print("\(Colour.red)\(error.localizedDescription)\(Colour.reset)")
        return 1
    }
}

func listBottles() -> Int32 {
    guard let backend = resolveBackend() else { return 1 }
    let bottles = BottleManager(backend: backend).list()

    guard !bottles.isEmpty else {
        print("\nNo bottles yet. Create one with:\n  easyplay bottle-create \"My Game\" --recipe ride-4\n")
        return 0
    }

    print("\n\(Colour.bold)Bottles\(Colour.reset)\n")
    for bottle in bottles {
        let size = bottle.sizeOnDisk().map(formatBytes) ?? "unknown size"
        print("  \(Colour.bold)\(bottle.name)\(Colour.reset)")
        print("    \(Colour.dim)\(bottle.id)\(Colour.reset)")
        print("    \(bottle.windowsVersion) · \(bottle.graphicsBackend.displayName) · \(size)")
        if let recipeID = bottle.recipeID { print("    preset: \(recipeID)") }
        print("")
    }
    return 0
}

func createBottle(_ arguments: [String]) -> Int32 {
    guard let name = arguments.first, !name.hasPrefix("--") else {
        print("Usage: easyplay bottle-create <name> [--recipe <id>]")
        return 1
    }
    guard let backend = resolveBackend() else { return 1 }

    var recipe: Recipe?
    if let flagIndex = arguments.firstIndex(of: "--recipe"), flagIndex + 1 < arguments.count {
        do {
            recipe = try RecipeLibrary().recipe(id: arguments[flagIndex + 1])
        } catch {
            print("\(Colour.red)\(error.localizedDescription)\(Colour.reset)")
            return 1
        }
    }

    if let recipe, recipe.compatibility.rating == .notSupported {
        print("\n\(Colour.red)\(recipe.title) cannot run on a Mac.\(Colour.reset)")
        if let reason = recipe.compatibility.unsupportedReason { print("\n\(reason.explanation)\n") }
        return 1
    }

    print("\nCreating \"\(name)\" with \(backend.displayName)…\n")
    do {
        let bottle = try BottleManager(backend: backend).create(name: name, recipe: recipe) { message in
            print("  \(message)")
        }
        print("\n\(Colour.green)Created\(Colour.reset) \(bottle.name)")
        print("  \(Colour.dim)\(bottle.url.path)\(Colour.reset)\n")
        return 0
    } catch {
        print("\n\(Colour.red)\(error.localizedDescription)\(Colour.reset)\n")
        return 1
    }
}

func deleteBottle(_ arguments: [String]) -> Int32 {
    guard let id = arguments.first else {
        print("Usage: easyplay bottle-delete <id>")
        return 1
    }
    guard let backend = resolveBackend() else { return 1 }

    let manager = BottleManager(backend: backend)
    do {
        let bottle = try manager.bottle(id: id)
        try manager.delete(bottle)
        print("Deleted \"\(bottle.name)\".")
        return 0
    } catch {
        print("\(Colour.red)\(error.localizedDescription)\(Colour.reset)")
        return 1
    }
}

func verifyBottle(_ arguments: [String]) -> Int32 {
    guard let bottleID = arguments.first else {
        print("Usage: easyplay verify <bottle-id>")
        return 1
    }
    guard let backend = resolveBackend() else { return 1 }

    do {
        let bottle = try BottleManager(backend: backend).bottle(id: bottleID)
        let recipe = try RecipeLibrary().recipe(id: "winemine")

        print("\nChecking \"\(bottle.name)\" can run a Windows program…\n")

        let installer = GameInstaller(backend: backend)
        let game = try installer.registerExistingGame(in: bottle, recipe: recipe)
        print("  Found \(Colour.dim)\(game.executableRelativePath)\(Colour.reset)")

        print("  Starting it…")
        let outcome = try GameLauncher(backend: backend)
            .launch(game, in: bottle, recipe: recipe, timeout: 12)

        if outcome.succeeded {
            print("\n\(Colour.green)This bottle works.\(Colour.reset) A Windows program started and stayed running.\n")
            return 0
        }
        print("\n\(Colour.red)The program didn't start properly.\(Colour.reset)\n")
        reportDiagnoses(outcome.diagnoses, logURL: outcome.logURL)
        return 1
    } catch {
        print("\(Colour.red)\(error.localizedDescription)\(Colour.reset)")
        return 1
    }
}

func reportDiagnoses(_ diagnoses: [Diagnosis], logURL: URL?) {
    for diagnosis in diagnoses {
        print("  \(Colour.bold)\(diagnosis.title)\(Colour.reset)")
        print("  \(diagnosis.explanation)")
        if let remedy = diagnosis.remedy {
            print("  \(Colour.yellow)Suggested fix: \(remedy.buttonTitle)\(Colour.reset)")
        }
        if let evidence = diagnosis.evidence, !evidence.isEmpty {
            print("  \(Colour.dim)\(evidence.prefix(300))\(Colour.reset)")
        }
        print("")
    }
    if let logURL {
        print("  \(Colour.dim)Full log: \(logURL.path)\(Colour.reset)\n")
    }
}

func listGames() -> Int32 {
    let games = GameStore().load()
    guard !games.isEmpty else {
        print("\nNo games installed yet.\n")
        return 0
    }
    print("\n\(Colour.bold)Library\(Colour.reset)\n")
    for game in games.sorted(by: { $0.title < $1.title }) {
        print("  \(Colour.bold)\(game.title)\(Colour.reset)  \(badge(for: game.compatibilityRating))")
        print("    \(Colour.dim)\(game.id)\(Colour.reset)")
        print("    \(game.executableRelativePath)")
        if let played = game.lastPlayedAt {
            print("    last played \(played.formatted(date: .abbreviated, time: .shortened))")
        }
        print("")
    }
    return 0
}

func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func installGame(_ arguments: [String]) -> Int32 {
    guard let installerPath = arguments.first, !installerPath.hasPrefix("--") else {
        print("Usage: easyplay install <installer.exe> --bottle <id> [--recipe <id>]")
        return 1
    }
    guard let backend = resolveBackend() else { return 1 }

    let installerURL = URL(fileURLWithPath: (installerPath as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: installerURL.path) else {
        print("\(Colour.red)No file at \(installerURL.path)\(Colour.reset)")
        return 1
    }

    let library = RecipeLibrary()
    var recipe: Recipe?
    if let id = value(of: "--recipe", in: arguments) {
        recipe = try? library.recipe(id: id)
        if recipe == nil {
            print("\(Colour.red)No preset named '\(id)'.\(Colour.reset)")
            return 1
        }
    } else if let matched = library.matchRecipe(forInstallerNamed: installerURL.lastPathComponent) {
        recipe = matched
        print("\nRecognised this as \(Colour.bold)\(matched.title)\(Colour.reset) — applying its preset.")
    }

    do {
        let manager = BottleManager(backend: backend)
        let bottle: Bottle
        if let bottleID = value(of: "--bottle", in: arguments) {
            bottle = try manager.bottle(id: bottleID)
        } else {
            let name = recipe?.title ?? installerURL.deletingPathExtension().lastPathComponent
            print("\nNo bottle given, so creating one called \"\(name)\".\n")
            bottle = try manager.create(name: name, recipe: recipe) { print("  \($0)") }
        }

        print("")
        let game = try GameInstaller(backend: backend)
            .install(installerAt: installerURL, into: bottle, recipe: recipe) { print("  \($0)") }

        print("\n\(Colour.green)Installed\(Colour.reset) \(game.title)")
        print("  play it with: easyplay play \(game.id)\n")
        return 0
    } catch let error as InstallError {
        print("\n\(Colour.red)\(error.localizedDescription)\(Colour.reset)\n")
        if case .installerFailed(_, let diagnoses) = error { reportDiagnoses(diagnoses, logURL: nil) }
        return 1
    } catch {
        print("\n\(Colour.red)\(error.localizedDescription)\(Colour.reset)\n")
        return 1
    }
}

func playGame(_ arguments: [String]) -> Int32 {
    guard let gameID = arguments.first else {
        print("Usage: easyplay play <game-id> [--seconds <n>]")
        return 1
    }
    guard let backend = resolveBackend() else { return 1 }
    guard let game = GameStore().load().first(where: { $0.id == gameID }) else {
        print("\(Colour.red)No game with ID '\(gameID)'. Run 'easyplay games' to see them.\(Colour.reset)")
        return 1
    }

    let seconds = value(of: "--seconds", in: arguments).flatMap(Double.init)

    do {
        let bottle = try BottleManager(backend: backend).bottle(id: game.bottleID)
        let recipe = game.recipeID.flatMap { try? RecipeLibrary().recipe(id: $0) }

        print("\nLaunching \(Colour.bold)\(game.title)\(Colour.reset)…\n")
        let outcome = try GameLauncher(backend: backend)
            .launch(game, in: bottle, recipe: recipe, timeout: seconds)

        if outcome.succeeded {
            print("\(Colour.green)\(game.title) ran and exited cleanly.\(Colour.reset)\n")
            return 0
        }
        print("\(Colour.red)\(game.title) didn't run properly.\(Colour.reset)\n")
        reportDiagnoses(outcome.diagnoses, logURL: outcome.logURL)
        return 1
    } catch {
        print("\(Colour.red)\(error.localizedDescription)\(Colour.reset)")
        return 1
    }
}

// MARK: - Dispatch

let exitCode: Int32
switch arguments.first {
case "doctor":
    exitCode = doctor()
case "recipes":
    exitCode = arguments.count > 1 ? showRecipe(arguments[1]) : listRecipes()
case "bottles":
    exitCode = listBottles()
case "bottle-create":
    exitCode = createBottle(Array(arguments.dropFirst()))
case "bottle-delete":
    exitCode = deleteBottle(Array(arguments.dropFirst()))
case "verify":
    exitCode = verifyBottle(Array(arguments.dropFirst()))
case "games":
    exitCode = listGames()
case "install":
    exitCode = installGame(Array(arguments.dropFirst()))
case "play":
    exitCode = playGame(Array(arguments.dropFirst()))
case nil, "help", "-h", "--help":
    printUsage()
    exitCode = 0
default:
    print("Unknown command '\(arguments[0])'.\n")
    printUsage()
    exitCode = 1
}

exit(exitCode)
