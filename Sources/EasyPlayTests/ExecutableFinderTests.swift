import Foundation
import EasyPlayKit

enum ExecutableFinderTests {

    private static func matches(_ glob: String, _ path: String) -> Bool {
        guard let regex = ExecutableFinder.regex(forGlob: glob) else { return false }
        return regex.firstMatch(in: path, options: [], range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// Builds a throwaway bottle tree on disk with the files named.
    private static func makeBottle(_ files: [(String, Int, Date)]) -> Bottle? {
        let bottle = Bottle(id: "finder-test-\(UUID().uuidString)", name: "Finder test")
        for (relative, size, date) in files {
            let url = bottle.driveC.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard (try? Data(repeating: 0, count: size).write(to: url)) != nil else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return bottle
    }

    static func run() throws {
        Harness.suite("Executable discovery in a real bottle") {
            let installStart = Date()
            let old = installStart.addingTimeInterval(-3600)
            let new = installStart.addingTimeInterval(30)

            // A bottle is full of Windows' own programs from the moment it is
            // created. cmd.exe is bigger than many real game binaries, so a
            // "largest wins" search over `**/*.exe` used to pick it.
            guard let bottle = makeBottle([
                ("windows/syswow64/cmd.exe", 1_007_616, old),
                ("windows/system32/winecfg.exe", 823_296, old),
                ("Program Files/My Game/MyGame.exe", 400_000, new),
                ("Program Files/My Game/unins000.exe", 900_000, new),
                ("Program Files/My Game/vcredist_x64.exe", 800_000, new),
            ]) else {
                Harness.expect(false, "test bottle could be created")
                return
            }
            defer { try? FileManager.default.removeItem(at: bottle.url) }

            let finder = ExecutableFinder()
            let found = finder.find(glob: "**/*.exe", in: bottle, installedAfter: installStart)
            Harness.expectEqual(found?.lastPathComponent, "MyGame.exe",
                                "the installed game wins over Windows' own programs")

            Harness.expect(finder.candidates(glob: "**/*.exe", in: bottle)
                            .allSatisfy { !$0.path.contains("/windows/") },
                           "Windows system executables are never candidates")

            Harness.expect(finder.candidates(glob: "**/*.exe", in: bottle)
                            .allSatisfy { !$0.lastPathComponent.hasPrefix("unins") },
                           "uninstallers are not mistaken for the game")
            Harness.expect(finder.candidates(glob: "**/*.exe", in: bottle)
                            .allSatisfy { !$0.lastPathComponent.hasPrefix("vcredist") },
                           "bundled runtime installers are not mistaken for the game")

            // The case behind the bug: an installer that produced nothing must
            // yield nothing, not the largest file that happened to be lying about.
            guard let empty = makeBottle([
                ("windows/syswow64/cmd.exe", 1_007_616, old),
                ("windows/system32/winemine.exe", 200_000, old),
            ]) else { return }
            defer { try? FileManager.default.removeItem(at: empty.url) }
            Harness.expect(finder.find(glob: "**/*.exe", in: empty, installedAfter: installStart) == nil,
                           "an install that wrote nothing finds nothing, rather than cmd.exe")
        }

        Harness.suite("Executable globs") {
            Harness.expect(matches("**/RIDE4.exe", "/Program Files/Steam/steamapps/common/RIDE 4/RIDE4.exe"),
                           "** crosses directories")
            Harness.expect(matches("**/RIDE4.exe", "/RIDE4.exe"),
                           "** also matches at the root")
            Harness.expect(!matches("/Program Files/*.exe", "/Program Files/7-Zip/7zFM.exe"),
                           "a single * does not cross directories")
            Harness.expect(matches("/Program Files/*.exe", "/Program Files/thing.exe"),
                           "a single * matches within one directory")
            Harness.expect(matches("**/ride4.exe", "/Games/RIDE 4/RIDE4.EXE"),
                           "matching is case-insensitive, because Windows paths are")
            Harness.expect(!matches("**/RIDE4.exe", "/Games/RIDE4.exe.bak"),
                           "globs are anchored, so partial names do not match")
            Harness.expect(matches("**/7-Zip/7zFM.exe", "/Program Files/7-Zip/7zFM.exe"),
                           "path segments inside a glob are respected")
            Harness.expect(!matches("**/7-Zip/7zFM.exe", "/Program Files/Other/7zFM.exe"),
                           "a wrong parent directory does not match")
        }
    }
}
