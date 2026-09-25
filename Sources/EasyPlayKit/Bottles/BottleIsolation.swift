import Foundation

/// Keeps a bottle's Windows user folders inside the bottle.
///
/// Wine links the Windows "Documents", "Downloads", "Pictures" and "Music"
/// folders straight at the Mac ones, so a Windows game saving to `My Documents`
/// writes into the real `~/Documents`. That is a reasonable default for an
/// office application; for a game launcher it quietly breaks the promise the
/// rest of EasyPlay makes — that a bottle is self-contained, and deleting one
/// removes everything that game put on the Mac. TrackMania created
/// `~/Documents/TmForever` this way.
///
/// So the links are replaced with ordinary folders inside the bottle. Games
/// still find their save folder; it just lives in the bottle now.
///
/// Wine recreates the links whenever it updates a prefix — `wineboot --update`
/// after an engine move does exactly that — so this runs again before every
/// launch rather than only at creation. It is cheap: a handful of `lstat` calls
/// on a directory that is already warm.
public enum BottleIsolation {

    /// Replaces every link out of the bottle with a real folder, and returns the
    /// Windows folder names that were changed.
    ///
    /// Only direct children of a user's profile are considered, and only when
    /// they are symlinks pointing outside the bottle: an ordinary folder is left
    /// alone, and so is a link that stays inside the bottle.
    @discardableResult
    public static func isolateUserFolders(in bottleURL: URL,
                                          fileManager: FileManager = .default) -> [String] {
        let users = bottleURL.appendingPathComponent("drive_c/users", isDirectory: true)
        guard let profiles = try? fileManager.contentsOfDirectory(
            at: users, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        let bottlePath = bottleURL.resolvingSymlinksInPath().path
        var changed: [String] = []

        for profile in profiles {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: profile, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }

            for entry in entries {
                guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: entry.path) else {
                    continue  // Not a symlink: already a real folder.
                }
                // A relative link is resolved against the folder holding it.
                let resolved = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination)
                    : entry.deletingLastPathComponent().appendingPathComponent(destination)
                let target = resolved.resolvingSymlinksInPath().path
                guard target != bottlePath, !target.hasPrefix(bottlePath + "/") else {
                    continue  // Points somewhere inside the bottle; that's fine.
                }

                // Replace, never follow: removing the link deletes the link
                // itself, and the Mac folder it pointed at is untouched.
                do {
                    try fileManager.removeItem(at: entry)
                    try fileManager.createDirectory(at: entry, withIntermediateDirectories: true)
                    changed.append(entry.lastPathComponent)
                } catch {
                    continue  // A folder we can't fix is not a reason to block a launch.
                }
            }
        }

        return changed.sorted()
    }
}
