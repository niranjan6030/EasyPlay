import Foundation
import EasyPlayKit

/// A bottle is meant to hold everything a game puts on the Mac, so that deleting
/// it really does remove the game. Wine's default of linking the Windows user
/// folders at the real Mac ones quietly breaks that, and it is the kind of thing
/// nobody notices until a game has already written somewhere personal.
enum BottleIsolationTests {

    static func run() throws {
        Harness.suite("Bottle isolation") {
            let fileManager = FileManager.default
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("easyplay-isolation-\(UUID().uuidString)")
            let bottle = root.appendingPathComponent("bottle")
            let profile = bottle.appendingPathComponent("drive_c/users/crossover")
            let outside = root.appendingPathComponent("Home/Documents")
            defer { try? fileManager.removeItem(at: root) }

            do {
                try fileManager.createDirectory(at: profile, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
                try "a file the user already had".write(
                    to: outside.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

                // What Wine leaves behind: a link out to the user's real folder…
                try fileManager.createSymbolicLink(
                    at: profile.appendingPathComponent("Documents"), withDestinationURL: outside)
                // …an ordinary folder, which must be left alone…
                try fileManager.createDirectory(
                    at: profile.appendingPathComponent("Saved Games"), withIntermediateDirectories: true)
                // …and a link that stays inside the bottle, which is harmless.
                try fileManager.createSymbolicLink(
                    at: profile.appendingPathComponent("Inside"),
                    withDestinationURL: bottle.appendingPathComponent("drive_c"))
            } catch {
                Harness.expect(false, "isolation fixture could be built: \(error)")
                return
            }

            let changed = BottleIsolation.isolateUserFolders(in: bottle)
            Harness.expectEqual(changed, ["Documents"],
                                "only the link pointing out of the bottle is replaced")

            let documents = profile.appendingPathComponent("Documents")
            var isDirectory: ObjCBool = false
            Harness.expect(fileManager.fileExists(atPath: documents.path, isDirectory: &isDirectory)
                           && isDirectory.boolValue,
                           "the game still finds a Documents folder")
            Harness.expect((try? fileManager.destinationOfSymbolicLink(atPath: documents.path)) == nil,
                           "and it is a real folder inside the bottle, not a link out of it")

            // Removing a link must never take the user's files with it.
            Harness.expect(fileManager.fileExists(atPath: outside.appendingPathComponent("notes.txt").path),
                           "the user's own files are untouched")
            Harness.expect((try? fileManager.destinationOfSymbolicLink(
                atPath: profile.appendingPathComponent("Inside").path)) != nil,
                           "a link that stays inside the bottle is left alone")

            // Wine re-links these on every prefix update, so it has to be safe
            // to run again and again.
            Harness.expectEqual(BottleIsolation.isolateUserFolders(in: bottle), [],
                                "running it again changes nothing")
        }

        Harness.suite("Off-screen windows") {
            let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)

            // The real case: Wine 11 opened TrackMania's dialog at x = -2577.
            let stranded = CGRect(x: -2577, y: 400, width: 420, height: 180)
            Harness.expect(WindowRescue.isOffScreen(stranded, screens: [screen]),
                           "a window no display covers is off-screen")
            Harness.expect(!WindowRescue.isOffScreen(CGRect(x: 100, y: 800, width: 600, height: 400),
                                                     screens: [screen]),
                           "a window hanging off the bottom edge is normal, and left alone")
            Harness.expect(!WindowRescue.isOffScreen(stranded, screens: []),
                           "with no displays readable, nothing is declared off-screen")

            // A second display makes the same coordinates legitimate.
            let left = CGRect(x: -3000, y: 0, width: 1920, height: 1080)
            Harness.expect(!WindowRescue.isOffScreen(stranded, screens: [screen, left]),
                           "a window on another display is where it belongs")

            let rescued = WindowRescue.rescuePosition(for: stranded, on: screen)
            Harness.expect(screen.contains(CGRect(origin: rescued, size: stranded.size)),
                           "a rescued window lands fully on screen")
            Harness.expect(rescued.y >= screen.minY,
                           "and never above the top edge, where its title bar can't be grabbed")
        }
    }
}
