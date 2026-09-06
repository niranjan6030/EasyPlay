import Foundation

/// Everything EasyPlay writes lives under one directory, so uninstalling is
/// "delete this folder" and nothing is hidden anywhere surprising.
public enum AppPaths {
    public static let bundleIdentifier = "com.easyplay.EasyPlay"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EasyPlay", isDirectory: true)
    }

    /// One Wine prefix per game, never shared. A broken game can then be thrown
    /// away without touching anything else.
    public static var bottlesDirectory: URL {
        supportDirectory.appendingPathComponent("Bottles", isDirectory: true)
    }

    public static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    /// Downloaded DXVK releases, shared across bottles.
    public static var runtimesDirectory: URL {
        supportDirectory.appendingPathComponent("Runtimes", isDirectory: true)
    }

    public static var libraryFile: URL {
        supportDirectory.appendingPathComponent("library.json")
    }

    @discardableResult
    public static func ensureDirectories() throws -> URL {
        for directory in [supportDirectory, bottlesDirectory, logsDirectory,
                          runtimesDirectory, RecipeLibrary.userRecipesDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return supportDirectory
    }
}
