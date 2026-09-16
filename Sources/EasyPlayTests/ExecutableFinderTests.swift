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
            let old = Date().addingTimeInterval(-3600)

            // A bottle is full of Windows' own programs from the moment it is
            // created. cmd.exe is bigger than many real game binaries, so a
            // "largest wins" search over `**/*.exe` used to pick it.
            guard let bottle = makeBottle([
                ("windows/syswow64/cmd.exe", 1_007_616, old),
                ("windows/system32/winecfg.exe", 823_296, old),
            ]) else {
                Harness.expect(false, "test bottle could be created")
                return
            }
            defer { try? FileManager.default.removeItem(at: bottle.url) }

            let finder = ExecutableFinder()
            let before = finder.snapshot(of: bottle)

            // Installers preserve archive timestamps — 7-Zip's files are dated
            // 2023 — so the game is identified by being *new to the bottle*,
            // never by being recently modified.
            for (relative, size) in [
                ("Program Files/My Game/MyGame.exe", 400_000),
                ("Program Files/My Game/unins000.exe", 900_000),
                ("Program Files/My Game/vcredist_x64.exe", 800_000),
                ("users/crossover/Temp/is-94N4S.tmp/xtool.exe", 2_000_000),
            ] {
                let url = bottle.driveC.appendingPathComponent(relative)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? Data(repeating: 0, count: size).write(to: url)
                try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }

            let found = finder.find(glob: "**/*.exe", in: bottle, ignoring: before)
            Harness.expectEqual(found?.lastPathComponent, "MyGame.exe",
                                "the installed game is found even with 2023 timestamps")

            let names = finder.candidates(glob: "**/*.exe", in: bottle, ignoring: before)
                .map(\.lastPathComponent)
            Harness.expect(!names.contains("cmd.exe"), "Windows' own programs are never candidates")
            Harness.expect(!names.contains("unins000.exe"), "uninstallers are not mistaken for the game")
            Harness.expect(!names.contains("vcredist_x64.exe"), "bundled runtimes are not mistaken for the game")
            // The bug a repack installer actually caused: its temporary
            // extractor is new, large, and not a game.
            Harness.expect(!names.contains("xtool.exe"),
                           "an installer's temp-directory extractor is not mistaken for the game")

            // Regression: the bottle health check targets Wine's own Minesweeper
            // in windows/system32. Skipping system programs while guessing must
            // not stop a preset that names one on purpose.
            guard let mine = makeBottle([("windows/system32/winemine.exe", 200_000, old)]) else { return }
            defer { try? FileManager.default.removeItem(at: mine.url) }
            Harness.expect(finder.find(glob: "**/winemine.exe", in: mine) == nil,
                           "a guessing search skips Windows' own programs")
            Harness.expect(finder.find(glob: "**/winemine.exe", in: mine, skippingSupportFiles: false) != nil,
                           "a preset naming a system program still finds it")

            // An install that added nothing must find nothing.
            guard let empty = makeBottle([("windows/syswow64/cmd.exe", 1_007_616, old)]) else { return }
            defer { try? FileManager.default.removeItem(at: empty.url) }
            Harness.expect(finder.find(glob: "**/*.exe", in: empty,
                                       ignoring: finder.snapshot(of: empty)) == nil,
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

/// Where a game's program ends up once its folder is moved into a bottle.
enum ImportPathTests {
    static func run() throws {
        Harness.suite("Import path maths") {
            let bottle = Bottle(id: "b1", name: "Cave Story")
            let destination = bottle.driveC.appendingPathComponent("Games/Cave Story")

            // The case that broke a real install: macOS reports a temporary
            // folder as /var/… while files inside it resolve to /private/var/…,
            // so replacing one path inside the other mangled the result.
            let folder = URL(fileURLWithPath: "/var/folders/xy/easyplay-import-1")
            let exe = URL(fileURLWithPath: "/private/var/folders/xy/easyplay-import-1/CaveStory/Doukutsu.exe")
            let rel = GameInstaller.relativePath(of: exe, movedFrom: folder, to: destination, in: bottle)
            Harness.expectEqual(rel, "drive_c/Games/Cave Story/CaveStory/Doukutsu.exe",
                                "the program's path survives the move")
            Harness.expect(!rel.hasPrefix("/"), "the stored path is relative to the bottle")

            // A program at the top of the folder, no subdirectory.
            let flat = URL(fileURLWithPath: "/var/folders/xy/easyplay-import-1/iji.exe")
            Harness.expectEqual(GameInstaller.relativePath(of: flat, movedFrom: folder, to: destination, in: bottle),
                                "drive_c/Games/Cave Story/iji.exe",
                                "a program at the top level is handled too")
        }
    }
}

/// What the Install window accepts, whether dropped or chosen.
enum DropAcceptanceTests {
    static func run() throws {
        Harness.suite("What can be installed") {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("easyplay-drop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            Harness.expect(GameInstaller.canInstall(URL(fileURLWithPath: "/x/setup.exe")), "an installer is accepted")
            Harness.expect(GameInstaller.canInstall(URL(fileURLWithPath: "/x/game.msi")), "an .msi is accepted")
            Harness.expect(GameInstaller.canInstall(URL(fileURLWithPath: "/x/disc.iso")), "an .iso is accepted")
            Harness.expect(GameInstaller.canInstall(URL(fileURLWithPath: "/x/game.zip")), "a zip is accepted")
            Harness.expect(GameInstaller.canInstall(tmp), "a game folder is accepted")
            Harness.expect(GameInstaller.canInstall(URL(fileURLWithPath: "/x/game.RAR")),
                           "a .rar is accepted here, then refused with advice rather than ignored silently")
            Harness.expect(!GameInstaller.canInstall(URL(fileURLWithPath: "/x/notes.txt")),
                           "an unrelated file is not accepted")
            Harness.expect(!GameInstaller.canInstall(URL(fileURLWithPath: "/x/photo.png")),
                           "an image is not accepted")

            Harness.expect(GameInstaller.isImportable(URL(fileURLWithPath: "/x/game.zip")),
                           "a zip is copied in, not run as an installer")
            Harness.expect(!GameInstaller.isImportable(URL(fileURLWithPath: "/x/setup.exe")),
                           "an installer is run, not copied in")
        }
    }
}
