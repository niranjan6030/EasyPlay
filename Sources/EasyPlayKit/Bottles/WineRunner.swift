import Foundation

/// Runs Wine against one bottle.
///
/// Everything Wine needs in order to behave — which prefix, which graphics
/// translator, which DLL overrides, where its Mac-side libraries live — arrives
/// as environment variables. Getting that environment right by hand, every time,
/// is exactly the chore EasyPlay exists to remove, so it is built in one place
/// and unit-tested.
public struct WineRunner {

    /// How much Wine should say about what it is doing.
    public enum Verbosity {
        /// Quiet, for normal play — Wine's debug channels cost frame rate.
        case play
        /// Errors and warnings kept, for the log classifier to read.
        case diagnostic

        var wineDebugValue: String {
            switch self {
            case .play: return "-all"
            case .diagnostic: return "err+all,fixme-all"
            }
        }
    }

    public let backend: WineBackend
    public let bottle: Bottle
    private let runner: ProcessRunner

    public init(backend: WineBackend, bottle: Bottle, runner: ProcessRunner = ProcessRunner()) {
        self.backend = backend
        self.bottle = bottle
        self.runner = runner
    }

    /// Builds the environment a Wine invocation runs in.
    ///
    /// Exposed rather than private because it is the single most failure-prone
    /// part of driving Wine, and the part most worth testing directly.
    public func environment(recipe: Recipe? = nil,
                            verbosity: Verbosity = .play,
                            extraOverrides: [String: String] = [:]) -> [String: String] {
        var environment: [String: String] = [
            "WINEPREFIX": bottle.url.path,
            "WINEARCH": bottle.architecture,
            "WINEDEBUG": verbosity.wineDebugValue,
        ]

        // Apple's D3DMetal is a Mac framework that Wine's patched d3d11/dxgi DLLs
        // load at runtime. Without this path the DLLs load but find nothing to
        // talk to, and the game fails with an unhelpful device-creation error.
        if let externalLibraries = backend.externalLibraryDirectory {
            let wineLibraries = backend.binDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("lib", isDirectory: true)
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = [
                externalLibraries.path,
                wineLibraries.path,
                "/usr/lib",
            ].joined(separator: ":")
        }

        if let recipe {
            environment.merge(recipe.environment) { _, new in new }
        }

        var overrides = recipe?.dllOverrides ?? [:]
        overrides.merge(extraOverrides) { _, new in new }
        overrides.merge(graphicsOverrides(for: recipe?.graphics.backend ?? bottle.graphicsBackend)) { current, _ in current }

        if !overrides.isEmpty {
            environment["WINEDLLOVERRIDES"] = Self.formatDLLOverrides(overrides)
        }

        return environment
    }

    /// Formats an override table the way Wine expects it: DLLs sharing a load
    /// order are grouped, groups are separated by semicolons, e.g.
    /// `d3d11,dxgi=builtin;nvapi=disabled`.
    public static func formatDLLOverrides(_ overrides: [String: String]) -> String {
        Dictionary(grouping: overrides.keys, by: { overrides[$0]! })
            .sorted { $0.key < $1.key }
            .map { "\($0.value.sorted().joined(separator: ","))=\($0.key)" }
            .joined(separator: ";")
    }

    /// DLL load order implied by a choice of graphics translator.
    ///
    /// On Game Porting Toolkit the *built-in* d3d11/dxgi DLLs are D3DMetal, so
    /// selecting D3DMetal means preferring built-in. DXVK ships its own PE DLLs
    /// into the bottle, so it means preferring native.
    public func graphicsOverrides(for graphics: GraphicsBackend) -> [String: String] {
        switch graphics {
        case .d3dMetal, .wineD3D:
            return ["d3d9": "builtin", "d3d10core": "builtin", "d3d11": "builtin", "dxgi": "builtin"]
        case .dxvk:
            return ["d3d9": "native", "d3d10core": "native", "d3d11": "native", "dxgi": "native"]
        }
    }

    @discardableResult
    public func run(_ arguments: [String],
                    recipe: Recipe? = nil,
                    verbosity: Verbosity = .play,
                    workingDirectory: URL? = nil,
                    timeout: TimeInterval? = nil,
                    onOutput: ProcessRunner.OutputHandler? = nil) throws -> CommandResult {
        try runner.run(
            backend.wine64.path,
            arguments,
            environment: environment(recipe: recipe, verbosity: verbosity),
            workingDirectory: workingDirectory,
            timeout: timeout,
            onOutput: onOutput
        )
    }

    /// Applies a batch of registry values in a single Wine launch, then waits
    /// for Wine to flush them to disk so the change is durable before returning.
    public func apply(_ patch: RegistryPatch) throws {
        guard !patch.isEmpty else { return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("easyplay-\(UUID().uuidString).reg")
        try patch.regFileContents.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        _ = try run(["regedit", "/S", file.path], verbosity: .play, timeout: 180)
        _ = try runner.run(backend.wineserver.path, ["-w"],
                           environment: ["WINEPREFIX": bottle.url.path], timeout: 60)
    }

    /// Writes a registry value into the bottle.
    @discardableResult
    public func setRegistryValue(key: String, name: String, value: String,
                                 type: String = "REG_SZ") throws -> CommandResult {
        try run(["reg", "add", key, "/v", name, "/t", type, "/d", value, "/f"],
                verbosity: .diagnostic, timeout: 120)
    }

    /// Blocks until Wine's background server for this bottle has exited. Wine
    /// keeps state in `wineserver`, so tearing a bottle down or reconfiguring it
    /// while the server is alive produces confusing, intermittent failures.
    @discardableResult
    public func shutdown(timeout: TimeInterval = 30) throws -> CommandResult {
        try runner.run(
            backend.wineserver.path, ["-k"],
            environment: ["WINEPREFIX": bottle.url.path],
            timeout: timeout
        )
    }
}
