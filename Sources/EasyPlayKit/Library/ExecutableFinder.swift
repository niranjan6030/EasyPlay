import Foundation

/// Locates a game's executable inside a bottle.
///
/// Installers decide their own layout, and a preset can't hard-code an absolute
/// path that will hold across versions and regions. So recipes describe the
/// executable with a glob and this resolves it after the install finishes.
public struct ExecutableFinder {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Windows' own programs. A bottle contains dozens of these from the moment
    /// it is created, and none of them is ever the game the user installed.
    /// Windows' own programs, and the scratch space installers unpack into.
    /// An installer's temporary extractor is new, large, and not a game — it is
    /// the single most likely thing to be mistaken for one.
    private static let systemDirectories = [
        "/windows/",
        "/users/crossover/temp/",
        "/users/public/temp/",
        "/temp/",
        "/tmp/",
    ]

    /// Executables installers routinely leave beside a game.
    private static let notAGame = [
        "unins", "uninstall", "setup", "vcredist", "vc_redist", "dxsetup",
        "dotnetfx", "directx", "crashreport", "crashhandler", "cefprocess",
        "installer", "redist", "helper",
    ]

    /// Finds the executable matching `glob` under a bottle's C: drive.
    ///
    /// When several files match, the largest wins. Games routinely ship small
    /// launcher and crash-handler executables beside the real one, and the real
    /// one is almost always the biggest.
    ///
    /// `ignoring` is what stops a failed install registering nonsense: pass the
    /// snapshot taken before the installer ran and only genuinely new files are
    /// considered. A bottle is full of Windows' own executables, so a broad glob
    /// like `**/*.exe` would otherwise pick `cmd.exe` as "the game" when an
    /// installer produced nothing at all.
    ///
    /// This deliberately does *not* use file timestamps. Installers routinely
    /// preserve the original dates from their archives — 7-Zip's writes files
    /// dated 2023, creation date included — so "newer than when we started"
    /// silently rejects the real game.
    ///
    /// `skippingSupportFiles` should be false when a preset names a program
    /// deliberately — the bottle health check targets Wine's own Minesweeper in
    /// `windows/system32`, which the guessing heuristics would otherwise hide.
    public func find(glob: String, in bottle: Bottle, ignoring: Set<String> = [],
                     skippingSupportFiles: Bool = true) -> URL? {
        candidates(glob: glob, in: bottle, ignoring: ignoring, skippingSupportFiles: skippingSupportFiles)
            .max { size(of: $0) < size(of: $1) }
    }

    /// Every executable currently in the bottle, for diffing after an install.
    public func snapshot(of bottle: Bottle) -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: bottle.driveC, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }

        var paths = Set<String>()
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "exe" {
            paths.insert(url.path)
        }
        return paths
    }

    public func candidates(glob: String, in bottle: Bottle, ignoring: Set<String> = [],
                           skippingSupportFiles: Bool = true) -> [URL] {
        guard let regex = Self.regex(forGlob: glob),
              let enumerator = fileManager.enumerator(
                  at: bottle.driveC,
                  includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                               .contentModificationDateKey, .creationDateKey],
                  options: [.skipsHiddenFiles]) else { return [] }

        var matches: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "exe" else { continue }
            if skippingSupportFiles, isSystemOrSupportExecutable(fileURL, in: bottle) { continue }
            guard !ignoring.contains(fileURL.path) else { continue }
            // Match against the Windows-side path so globs in presets read the
            // way a Windows user would write them.
            let relativePath = fileURL.path
                .replacingOccurrences(of: bottle.driveC.path, with: "")
                .replacingOccurrences(of: "\\", with: "/")
            let range = NSRange(relativePath.startIndex..., in: relativePath)
            if regex.firstMatch(in: relativePath, options: [], range: range) != nil {
                matches.append(fileURL)
            }
        }
        return matches
    }

    /// Windows' own programs, and the uninstallers and runtime bundles an
    /// installer drops next to the game.
    private func isSystemOrSupportExecutable(_ url: URL, in bottle: Bottle) -> Bool {
        let relative = url.path
            .replacingOccurrences(of: bottle.driveC.path, with: "")
            .lowercased()
        if Self.systemDirectories.contains(where: { relative.hasPrefix($0) }) { return true }

        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return Self.notAGame.contains { name.hasPrefix($0) }
    }

    private func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
    }

    /// Converts a glob to an anchored regex.
    ///
    /// `**` crosses directory boundaries, `*` does not, `?` is one character.
    /// Matching is case-insensitive because Windows paths are.
    public static func regex(forGlob glob: String) -> NSRegularExpression? {
        var pattern = "^"
        let characters = Array(glob)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count && characters[index + 1] == "*" {
                    pattern += ".*"
                    index += 2
                    // Swallow the slash after "**/" so the glob also matches at
                    // the root, i.e. "**/game.exe" matches "/game.exe".
                    if index < characters.count && characters[index] == "/" { index += 1 }
                    continue
                }
                pattern += "[^/]*"
            case "?":
                pattern += "[^/]"
            case "/":
                pattern += "/"
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        pattern += "$"

        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
