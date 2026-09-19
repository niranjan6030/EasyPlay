import Foundation

/// One line item in the setup screen.
public struct EnvironmentCheck: Identifiable {
    public enum Status: String {
        /// Nothing to do.
        case ok
        /// Works, but something is degraded or worth knowing.
        case warning
        /// Games cannot run until this is fixed.
        case blocked
    }

    public let id: String
    public let title: String
    public let status: Status
    public let detail: String
    /// Plain-English next step, or nil when there is nothing to do.
    public let remedy: String?
    /// A shell command the user can copy, when the fix is a command.
    public let remedyCommand: String?

    public init(id: String, title: String, status: Status, detail: String,
                remedy: String? = nil, remedyCommand: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.remedy = remedy
        self.remedyCommand = remedyCommand
    }
}

public struct EnvironmentReport {
    public let system: SystemInfo
    public let homebrewVersion: String?
    public let backends: [WineBackend]
    public let preferredBackend: WineBackend?
    public let winetricksPath: URL?
    public let checks: [EnvironmentCheck]

    public init(system: SystemInfo, homebrewVersion: String?, backends: [WineBackend],
                preferredBackend: WineBackend?, winetricksPath: URL?, checks: [EnvironmentCheck]) {
        self.system = system
        self.homebrewVersion = homebrewVersion
        self.backends = backends
        self.preferredBackend = preferredBackend
        self.winetricksPath = winetricksPath
        self.checks = checks
    }

    /// True when a game could actually be installed and launched right now.
    public var isReady: Bool { !checks.contains { $0.status == .blocked } }

    public var blockers: [EnvironmentCheck] { checks.filter { $0.status == .blocked } }

    /// The engine of a given kind, or the preferred one when it isn't installed.
    public func backend(for kind: WineBackend.Kind?) -> WineBackend? {
        guard let kind else { return preferredBackend }
        return backends.first { $0.kind == kind } ?? preferredBackend
    }

    /// The engine a bottle was built with, so it keeps using the same one.
    public func backend(for bottle: Bottle) -> WineBackend? { backend(for: bottle.backendKind) }

    /// Which engine suits this game.
    ///
    /// The Game Porting Toolkit is the only engine with D3DMetal, so 64-bit
    /// DirectX games belong there. Everything else — and every 32-bit game,
    /// which cannot use D3DMetal and crashes on that engine's 2022 Wine — runs
    /// better on the modern Wine.
    public func backend(for recipe: Recipe?, architecture: WindowsExecutable.Architecture = .unknown) -> WineBackend? {
        if let required = recipe?.requires.backend { return backend(for: required) }
        // Measured on real games: every 32-bit game crashes on the Game Porting
        // Toolkit's 2022 Wine, and 32-bit code can't reach D3DMetal anyway. A
        // 64-bit game is the opposite — Cortex Command runs there and crashes on
        // the modern Wine. So architecture decides, not preference.
        //
        // Among the newer engines, Classic Wine (Wine 8) comes first: Wine 11
        // crashes some 32-bit games in its new WoW64 exception handling that
        // Wine 8 runs fine (TrackMania Nations Forever), and none tested so far
        // needed Wine 11 over it.
        if architecture == .x86,
           let engine = backends.first(where: { $0.kind == .classicWine })
                ?? backends.first(where: { $0.kind == .wineStaging }) {
            return engine
        }
        return backend(for: .gamePortingToolkit)
    }
    public var warnings: [EnvironmentCheck] { checks.filter { $0.status == .warning } }
}

/// Finds the Wine builds installed on this Mac and reports what is missing.
///
/// This is the first thing the app runs and the backbone of the setup screen:
/// every "you need to do X" message in the UI originates here, not from parsing
/// a failure after the fact.
public struct ToolchainDetector {

    /// Where Wine distributions are known to install themselves. Ordered by
    /// preference — Game Porting Toolkit first, because on Apple Silicon it is
    /// the build with working DirectX 11/12.
    private static let knownBundles: [(kind: WineBackend.Kind, appPath: String, translators: Set<GraphicsBackend>)] = [
        (.gamePortingToolkit, "/Applications/Game Porting Toolkit.app", [.d3dMetal, .wineD3D]),
        (.wineStaging, AppPaths.runtimesDirectory.appendingPathComponent("Wine Staging.app").path, [.wineD3D]),
        (.wineStaging, "/Applications/Wine Staging.app", [.wineD3D]),
        (.wineHQ, "/Applications/Wine Staging.app", [.wineD3D]),
        (.wineHQ, "/Applications/Wine Devel.app", [.wineD3D]),
        (.wineHQ, "/Applications/Wine Stable.app", [.wineD3D]),
    ]

    private let runner: ProcessRunner
    private let probe: SystemProbe
    private let brew: BrewClient
    private let fileManager: FileManager

    public init(runner: ProcessRunner = ProcessRunner(),
                probe: SystemProbe = SystemProbe(),
                brew: BrewClient = BrewClient(),
                fileManager: FileManager = .default) {
        self.runner = runner
        self.probe = probe
        self.brew = brew
        self.fileManager = fileManager
    }

    public func detect() -> EnvironmentReport {
        let system = probe.probe()
        let backends = discoverBackends()
        let preferred = backends.first
        let winetricks = ProcessRunner.locate("winetricks")
        let brewVersion = brew.version()

        let checks = buildChecks(
            system: system,
            brewVersion: brewVersion,
            backends: backends,
            preferred: preferred,
            winetricks: winetricks
        )

        return EnvironmentReport(
            system: system,
            homebrewVersion: brewVersion,
            backends: backends,
            preferredBackend: preferred,
            winetricksPath: winetricks,
            checks: checks
        )
    }

    // MARK: - Backend discovery

    public func discoverBackends() -> [WineBackend] {
        var found: [WineBackend] = []
        var seenPaths = Set<String>()

        for bundle in Self.knownBundles {
            let binDirectory = URL(fileURLWithPath: bundle.appPath)
                .appendingPathComponent("Contents/Resources/wine/bin", isDirectory: true)
            guard let backend = makeBackend(kind: bundle.kind,
                                            binDirectory: binDirectory,
                                            translators: bundle.translators),
                  seenPaths.insert(backend.binDirectory.resolvingSymlinksInPath().path).inserted else { continue }
            found.append(backend)
        }

        // Classic Wine isn't an app bundle; it's installed by EasyPlay itself.
        if let classic = makeBackend(kind: .classicWine,
                                     binDirectory: ClassicWineInstaller.binDirectory,
                                     translators: [.wineD3D]),
           ClassicWineInstaller.isInstalled,
           seenPaths.insert(classic.binDirectory.resolvingSymlinksInPath().path).inserted {
            found.append(classic)
        }

        // Anything else the user has on PATH, e.g. a self-built Wine. Symlinks are
        // resolved first: Homebrew links the Game Porting Toolkit binaries into
        // its own bin directory, and without resolving we would report the same
        // installation twice under two different names.
        for name in ["wine64", "wine"] where ProcessRunner.locate(name) != nil {
            guard let executable = ProcessRunner.locate(name) else { continue }
            let binDirectory = executable
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
            guard !seenPaths.contains(binDirectory.path),
                  let backend = makeBackend(kind: .custom,
                                            binDirectory: binDirectory,
                                            translators: [.wineD3D]) else { continue }
            seenPaths.insert(binDirectory.path)
            found.append(backend)
        }

        return found
    }

    private func makeBackend(kind: WineBackend.Kind,
                             binDirectory: URL,
                             translators: Set<GraphicsBackend>) -> WineBackend? {
        // Older builds ship only `wine`; newer ones only `wine64`. Accept either.
        let candidates = ["wine64", "wine"].map { binDirectory.appendingPathComponent($0) }
        guard let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }

        let version = readVersion(of: executable) ?? "unknown"
        var bundled = translators
        if hasDXVK(in: binDirectory) { bundled.insert(.dxvk) }

        return WineBackend(kind: kind, binDirectory: binDirectory,
                           version: version, bundledTranslators: bundled)
    }

    private func readVersion(of executable: URL) -> String? {
        // `wine --version` prints e.g. "wine-8.0.1 (Staging)".
        guard let result = try? runner.run(executable.path, ["--version"], timeout: 20),
              result.succeeded else { return nil }
        return result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "wine-", with: "")
    }

    /// Does this build ship DXVK itself? Game Porting Toolkit does not — it
    /// carries D3DMetal instead — so DXVK is normally installed per-bottle from
    /// a downloaded release rather than taken from the backend.
    private func hasDXVK(in binDirectory: URL) -> Bool {
        let externalDirectory = binDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("lib/external", isDirectory: true)
        return fileManager.fileExists(atPath: externalDirectory.appendingPathComponent("dxvk").path)
    }

    // MARK: - Checks

    private func buildChecks(system: SystemInfo,
                             brewVersion: String?,
                             backends: [WineBackend],
                             preferred: WineBackend?,
                             winetricks: URL?) -> [EnvironmentCheck] {
        var checks: [EnvironmentCheck] = []

        checks.append(EnvironmentCheck(
            id: "mac",
            title: "Your Mac",
            status: system.architecture == .unknown ? .blocked : .ok,
            detail: "\(system.chipName) · macOS \(system.macOSVersionString)"
        ))

        if system.needsRosetta {
            checks.append(EnvironmentCheck(
                id: "rosetta",
                title: "Rosetta 2",
                status: system.rosettaInstalled ? .ok : .blocked,
                detail: system.rosettaInstalled
                    ? "Installed. Windows games are Intel apps, and Rosetta is what lets them run on your chip."
                    : "Not installed. Windows games are Intel programs, so nothing can run without it.",
                remedy: system.rosettaInstalled ? nil : "Install Rosetta 2. It takes about a minute and only has to be done once.",
                remedyCommand: system.rosettaInstalled ? nil : "softwareupdate --install-rosetta --agree-to-license"
            ))
        }

        checks.append(EnvironmentCheck(
            id: "homebrew",
            title: "Homebrew",
            status: brewVersion == nil ? .blocked : .ok,
            detail: brewVersion.map { "Version \($0)" }
                ?? "Not installed. EasyPlay uses Homebrew to install and update the Wine engine.",
            remedy: brewVersion == nil ? "Install Homebrew, then reopen EasyPlay." : nil,
            remedyCommand: brewVersion == nil
                ? #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
                : nil
        ))

        if let preferred {
            let isRecommended = preferred.kind == .gamePortingToolkit
            checks.append(EnvironmentCheck(
                id: "wine",
                title: "Windows compatibility engine",
                status: isRecommended ? .ok : .warning,
                detail: isRecommended
                    ? "\(preferred.displayName) · DirectX support: \(translatorSummary(preferred))"
                    : "Found \(preferred.displayName), which has no Metal-based DirectX support. 3D games will be very slow.",
                remedy: isRecommended ? nil : "Install the Game Porting Toolkit engine for playable frame rates.",
                remedyCommand: isRecommended ? nil : brew.installCommand(for: BrewClient.gamePortingToolkit)
            ))
        } else {
            checks.append(EnvironmentCheck(
                id: "wine",
                title: "Windows compatibility engine",
                status: .blocked,
                detail: "No Wine installation found. This is the engine that actually runs Windows games.",
                remedy: "Let EasyPlay install it for you, or run the command below yourself. It is about a 2 GB download.",
                remedyCommand: brew.installCommand(for: BrewClient.gamePortingToolkit)
            ))
        }

        if preferred != nil {
            let classic = backends.first { $0.kind == .classicWine }
            checks.append(EnvironmentCheck(
                id: "classic-wine",
                title: "Engine for 32-bit games",
                status: classic == nil ? .warning : .ok,
                detail: classic.map { "\($0.displayName). Older games built for 32-bit Windows run on this." }
                    ?? "Not installed. Older 32-bit games crash on the Game Porting Toolkit, and some crash on newer Wine too.",
                remedy: classic == nil ? "Install Classic Wine (Wine 8, about 250 MB) for older games." : nil,
                remedyCommand: classic == nil ? "easyplay install-engine" : nil
            ))
        }

        checks.append(EnvironmentCheck(
            id: "winetricks",
            title: "Winetricks",
            status: winetricks == nil ? .warning : .ok,
            detail: winetricks == nil
                ? "Not installed. Some games need Windows runtimes that EasyPlay installs through Winetricks."
                : "Installed at \(winetricks!.path)",
            remedy: winetricks == nil ? "Install it so game presets can add missing Windows runtimes." : nil,
            remedyCommand: winetricks == nil ? brew.installCommand(for: BrewClient.winetricks) : nil
        ))

        let freeGB = Int(system.freeDiskGB)
        checks.append(EnvironmentCheck(
            id: "disk",
            title: "Free space",
            status: freeGB < 20 ? .blocked : (freeGB < 80 ? .warning : .ok),
            detail: "\(freeGB) GB available. Large games often need 50-80 GB.",
            remedy: freeGB < 80 ? "Free up space before installing a large game." : nil
        ))

        return checks
    }

    private func translatorSummary(_ backend: WineBackend) -> String {
        backend.bundledTranslators
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.displayName)
            .joined(separator: ", ")
    }
}
