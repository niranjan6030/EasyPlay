import Foundation
import Observation
import EasyPlayKit

/// The app's single source of truth.
///
/// Every long operation here runs off the main thread and reports progress back
/// onto it. Wine operations take minutes, and a launcher that beachballs while
/// creating a bottle would defeat the point of the project.
@MainActor
@Observable
final class AppModel {

    enum Screen: Hashable {
        case ask
        case library
        case bottles
        case setup
    }

    // MARK: - State

    var screen: Screen = .library
    var environment: EnvironmentReport?
    var bottles: [Bottle] = []
    var games: [InstalledGame] = []
    var recipes: [Recipe] = []

    /// Non-nil while a long operation is running.
    var activity: Activity?
    var alert: AlertContent?
    /// Diagnoses from the most recent failure, shown in a sheet.
    var diagnoses: [Diagnosis] = []

    struct Activity {
        var title: String
        var messages: [String] = []
    }

    struct AlertContent: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Shared so every answer in a session comes from one loaded catalogue.
    let advisor = CompatibilityAdvisor()

    /// Set when the user accepts a preset suggested by the advisor, so the
    /// library can open the install sheet with it already chosen.
    var pendingInstallPresetID: String?

    var backend: WineBackend? { environment?.preferredBackend }
    var isReady: Bool { environment?.isReady ?? false }

    // MARK: - Loading

    func refresh() {
        recipes = RecipeLibrary().all
        games = GameStore().load()

        Task.detached(priority: .userInitiated) {
            let report = ToolchainDetector().detect()
            let bottles = report.preferredBackend.map { BottleManager(backend: $0).list() } ?? []
            // Bottles can disappear outside EasyPlay, so the library is reconciled
            // against what is actually on disk every time it reloads.
            let games = GameStore().pruneOrphans(knownBottleIDs: Set(bottles.map(\.id)))
            await MainActor.run {
                self.environment = report
                self.bottles = bottles
                self.games = games
                // A first run with nothing installed should open on setup, not on
                // an empty library that gives no clue what to do next.
                if !report.isReady { self.screen = .setup }
            }
        }
    }

    func recipe(id: String?) -> Recipe? {
        guard let id else { return nil }
        return recipes.first { $0.id == id }
    }

    func bottle(id: String) -> Bottle? {
        bottles.first { $0.id == id }
    }

    // MARK: - Setup

    func installMissingDependency(_ package: BrewClient.Package) {
        run(title: "Installing \(package.name)") { report in
            try BrewClient().install(package) { line in
                // Homebrew is chatty; only its step headers are worth showing.
                if line.hasPrefix("==>") {
                    report(line.replacingOccurrences(of: "==> ", with: ""))
                }
            }
        }
    }

    // MARK: - Bottles

    func createBottle(named name: String, recipe: Recipe?) {
        guard let backend else { return }
        run(title: "Creating \(name)") { report in
            _ = try BottleManager(backend: backend).create(name: name, recipe: recipe, onProgress: report)
        }
    }

    func deleteBottle(_ bottle: Bottle) {
        guard let backend else { return }
        run(title: "Deleting \(bottle.name)") { _ in
            // BottleManager also clears the library entries that pointed here.
            try BottleManager(backend: backend).delete(bottle)
        }
    }

    /// Runs a Windows program in a bottle to prove it works, before the user
    /// commits to a long install.
    func verifyBottle(_ bottle: Bottle) {
        guard let backend else { return }
        run(title: "Checking \(bottle.name)") { report in
            let recipe = try RecipeLibrary().recipe(id: "winemine")
            report("Looking for a Windows program to run…")
            let game = try GameInstaller(backend: backend).registerExistingGame(in: bottle, recipe: recipe)
            report("Starting it…")
            let outcome = try GameLauncher(backend: backend)
                .launch(game, in: bottle, recipe: recipe, timeout: 12)
            try? GameStore().remove(id: game.id)
            guard outcome.succeeded else {
                throw DisplayError(message: "This bottle couldn't run a Windows program.",
                                   diagnoses: outcome.diagnoses)
            }
            report("This bottle works.")
        }
    }

    // MARK: - Installing

    func install(installerAt url: URL, recipe: Recipe?, bottleName: String) {
        guard let backend else { return }
        run(title: "Installing \(recipe?.title ?? url.lastPathComponent)") { report in
            let manager = BottleManager(backend: backend)
            let bottle = try manager.create(name: bottleName, recipe: recipe, onProgress: report)
            _ = try GameInstaller(backend: backend)
                .install(installerAt: url, into: bottle, recipe: recipe, onProgress: report)
        }
    }

    // MARK: - Playing

    func play(_ game: InstalledGame) {
        guard let backend, let bottle = bottle(id: game.bottleID) else { return }
        let recipe = recipe(id: game.recipeID)

        run(title: "Playing \(game.title)", showsWindow: false) { report in
            report("Starting \(game.title)…")
            let outcome = try GameLauncher(backend: backend).launch(game, in: bottle, recipe: recipe)
            guard outcome.succeeded else {
                throw DisplayError(message: "\(game.title) stopped unexpectedly.",
                                   diagnoses: outcome.diagnoses)
            }
        }
    }

    /// Jumps from an answer straight into installing that game.
    func startInstall(withPreset recipeID: String) {
        pendingInstallPresetID = recipeID
        screen = .library
    }

    func removeGame(_ game: InstalledGame) {
        try? GameStore().remove(id: game.id)
        games = GameStore().load()
    }

    // MARK: - Remedies

    /// Applies a fix the diagnostics offered, so the error sheet is actionable
    /// rather than merely informative.
    func apply(_ remedy: Diagnosis.Remedy, to game: InstalledGame) {
        guard let backend, var bottle = bottle(id: game.bottleID) else { return }

        switch remedy {
        case .installWinetricksVerb(let verb):
            run(title: "Installing \(verb)") { report in
                report("Adding \(verb) to this game's bottle…")
                try BottleManager(backend: backend).applyWinetricksVerb(verb, to: bottle)
                report("Done. Try playing again.")
            }
        case .switchGraphics(let graphics):
            run(title: "Switching graphics") { report in
                report("Switching to \(graphics.displayName)…")
                bottle.graphicsBackend = graphics
                let manager = BottleManager(backend: backend)
                try manager.setGraphics(graphics, on: &bottle)
                report("Done. Try playing again.")
            }
        case .startSteam, .recreateBottle:
            alert = AlertContent(
                title: remedy.buttonTitle,
                message: "This fix isn't automated yet. See the game's preset for what to do by hand."
            )
        }
    }

    // MARK: - Plumbing

    /// An error that already carries a user-facing explanation.
    struct DisplayError: LocalizedError {
        let message: String
        var diagnoses: [Diagnosis] = []
        var errorDescription: String? { message }
    }

    /// Runs `work` off the main thread, funnelling progress and failures into the
    /// UI in one place so no call site has to repeat it.
    private func run(title: String,
                     showsWindow: Bool = true,
                     _ work: @escaping (@escaping (String) -> Void) throws -> Void) {
        if showsWindow { activity = Activity(title: title) }

        Task.detached(priority: .userInitiated) {
            let report: (String) -> Void = { message in
                Task { @MainActor in self.activity?.messages.append(message) }
            }

            do {
                try work(report)
                await MainActor.run {
                    self.activity = nil
                    self.refresh()
                }
            } catch let error as DisplayError {
                await MainActor.run {
                    self.activity = nil
                    self.diagnoses = error.diagnoses
                    if error.diagnoses.isEmpty {
                        self.alert = AlertContent(title: title, message: error.message)
                    }
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.activity = nil
                    self.alert = AlertContent(title: title, message: error.localizedDescription)
                    self.refresh()
                }
            }
        }
    }
}
