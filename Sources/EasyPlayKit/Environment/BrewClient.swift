import Foundation

/// Drives Homebrew for the one-time setup flow.
///
/// EasyPlay deliberately installs nothing by hand: every dependency is a normal
/// Homebrew package, so users can inspect, update and uninstall it with tools
/// they already trust.
public struct BrewClient {
    public struct Package {
        public let name: String
        /// Tap that must be added before `name` resolves, if it isn't core.
        public let tap: String?
        public let isCask: Bool
        public let purpose: String

        public init(name: String, tap: String? = nil, isCask: Bool, purpose: String) {
            self.name = name
            self.tap = tap
            self.isCask = isCask
            self.purpose = purpose
        }
    }

    /// The Wine build EasyPlay targets on Apple Silicon.
    ///
    /// The official `wine-stable` / `wine@devel` / `wine@staging` casks were
    /// disabled in homebrew-cask on 2026-09-01 for failing macOS Gatekeeper
    /// checks, so they are not an installable path today. Gcenx's Game Porting
    /// Toolkit cask is a prebuilt bundle that installs in one step.
    public static let gamePortingToolkit = Package(
        name: "game-porting-toolkit",
        tap: "Gcenx/wine",
        isCask: true,
        purpose: "The Wine build that actually runs the game, bundled with Apple's D3DMetal."
    )

    public static let winetricks = Package(
        name: "winetricks",
        isCask: false,
        purpose: "Installs Windows runtimes (Visual C++, .NET) that some games need."
    )

    public static let requiredPackages = [gamePortingToolkit, winetricks]

    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public var brewURL: URL? { ProcessRunner.locate("brew") }
    public var isInstalled: Bool { brewURL != nil }

    public func version() -> String? {
        guard isInstalled,
              let result = try? runner.run("brew", ["--version"], timeout: 20),
              result.succeeded else { return nil }
        return result.standardOutput
            .split(separator: "\n").first
            .map { $0.replacingOccurrences(of: "Homebrew ", with: "").trimmingCharacters(in: .whitespaces) }
    }

    public func isPackageInstalled(_ package: Package) -> Bool {
        guard isInstalled else { return false }
        let arguments = package.isCask ? ["list", "--cask", package.name] : ["list", "--formula", package.name]
        let result = try? runner.run("brew", arguments, timeout: 30)
        return result?.succeeded ?? false
    }

    /// Adds the tap and installs the package, streaming Homebrew's own output so
    /// the caller can show real progress on a multi-gigabyte download.
    public func install(_ package: Package, onOutput: ProcessRunner.OutputHandler? = nil) throws {
        guard isInstalled else { throw ProcessError.executableNotFound("brew") }

        // Homebrew prompts and auto-updates make a GUI-driven install unpredictable.
        let environment = [
            "NONINTERACTIVE": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
        ]

        if let tap = package.tap {
            try runner.runChecked("brew", ["tap", tap], environment: environment,
                                  timeout: 300, onOutput: onOutput)
        }

        var arguments = ["install"]
        if package.isCask { arguments.append("--cask") }
        arguments.append(package.tap.map { "\($0)/\(package.name)" } ?? package.name)

        try runner.runChecked("brew", arguments, environment: environment,
                              timeout: 1800, onOutput: onOutput)
    }

    /// The command a user would run themselves — shown in the UI so the setup
    /// step is never a black box.
    public func installCommand(for package: Package) -> String {
        var lines: [String] = []
        if let tap = package.tap { lines.append("brew tap \(tap)") }
        let target = package.tap.map { "\($0)/\(package.name)" } ?? package.name
        lines.append("brew install \(package.isCask ? "--cask " : "")\(target)")
        return lines.joined(separator: "\n")
    }
}
