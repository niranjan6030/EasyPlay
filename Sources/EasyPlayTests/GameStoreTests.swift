import Foundation
import EasyPlayKit

enum GameStoreTests {
    static func run() throws {
        Harness.suite("Game library") {
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("easyplay-tests-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: temporary) }

            let store = GameStore(fileURL: temporary)
            let living = InstalledGame(title: "Kept", bottleID: "bottle-a", recipeID: nil,
                                       executableRelativePath: "a.exe", compatibilityRating: .runsGreat)
            let orphan = InstalledGame(title: "Orphaned", bottleID: "bottle-gone", recipeID: nil,
                                       executableRelativePath: "b.exe", compatibilityRating: .runsGreat)

            do {
                try store.save([living, orphan])
                Harness.expectEqual(store.load().count, 2, "games round-trip through disk")

                // A bottle can vanish outside EasyPlay — dragged to the Trash —
                // and the library must not keep offering games that cannot launch.
                let surviving = store.pruneOrphans(knownBottleIDs: ["bottle-a"])
                Harness.expectEqual(surviving.count, 1, "entries without a bottle are dropped")
                Harness.expectEqual(surviving.first?.title, "Kept", "the reachable game is kept")
                Harness.expectEqual(store.load().count, 1, "the pruning is written back to disk")

                // Pruning must be idempotent, since it runs on every reload.
                Harness.expectEqual(store.pruneOrphans(knownBottleIDs: ["bottle-a"]).count, 1,
                                    "pruning again changes nothing")
            } catch {
                Harness.expect(false, "game store operations succeed: \(error)")
            }
        }
    }
}
