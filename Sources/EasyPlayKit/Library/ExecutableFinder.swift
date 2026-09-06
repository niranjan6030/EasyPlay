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

    /// Finds the executable matching `glob` under a bottle's C: drive.
    ///
    /// When several files match, the largest wins. Games routinely ship small
    /// launcher and crash-handler executables beside the real one, and the real
    /// one is almost always the biggest.
    public func find(glob: String, in bottle: Bottle) -> URL? {
        candidates(glob: glob, in: bottle)
            .max { size(of: $0) < size(of: $1) }
    }

    public func candidates(glob: String, in bottle: Bottle) -> [URL] {
        guard let regex = Self.regex(forGlob: glob),
              let enumerator = fileManager.enumerator(
                  at: bottle.driveC,
                  includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
                  options: [.skipsHiddenFiles]) else { return [] }

        var matches: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "exe" else { continue }
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
