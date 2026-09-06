import Foundation

/// An isolated Wine prefix — one per game.
///
/// Wine calls these "prefixes"; every other tool in this space calls them
/// bottles, and so does EasyPlay's UI, because "prefix" means nothing to someone
/// who just wants to play a game. One game per bottle is a deliberate cost:
/// it uses more disk than sharing, and in exchange a game that wrecks its own
/// configuration can be deleted and rebuilt without touching anything else.
public struct Bottle: Codable, Identifiable, Equatable {
    public let id: String
    public var name: String
    /// The preset this bottle was built from, if any.
    public var recipeID: String?
    public var createdAt: Date
    public var windowsVersion: String
    public var architecture: String
    public var graphicsBackend: GraphicsBackend
    /// Backend the bottle was created with. Prefixes are not always portable
    /// between Wine builds, so this is recorded rather than assumed.
    public var backendKind: WineBackend.Kind

    /// Where the prefix lives on disk.
    public var url: URL {
        AppPaths.bottlesDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// The prefix's simulated `C:\`.
    public var driveC: URL {
        url.appendingPathComponent("drive_c", isDirectory: true)
    }

    public var metadataURL: URL {
        url.appendingPathComponent("easyplay-bottle.json")
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: driveC.path)
    }

    /// Total size on disk, or nil if it can't be measured.
    public func sizeOnDisk() -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    public init(id: String = UUID().uuidString,
                name: String,
                recipeID: String? = nil,
                createdAt: Date = Date(),
                windowsVersion: String = "win10",
                architecture: String = "win64",
                graphicsBackend: GraphicsBackend = .d3dMetal,
                backendKind: WineBackend.Kind = .gamePortingToolkit) {
        self.id = id
        self.name = name
        self.recipeID = recipeID
        self.createdAt = createdAt
        self.windowsVersion = windowsVersion
        self.architecture = architecture
        self.graphicsBackend = graphicsBackend
        self.backendKind = backendKind
    }
}
