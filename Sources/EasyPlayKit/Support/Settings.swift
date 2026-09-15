import Foundation

/// The few things EasyPlay remembers between launches.
///
/// Deliberately small, and deliberately free of secrets: the Steam account
/// *name* is stored so a cached SteamCMD session can be reused. The password
/// never reaches EasyPlay, so there is nothing sensitive to store.
public struct EasyPlaySettings: Codable, Equatable {
    public var steamUsername: String?

    public init(steamUsername: String? = nil) {
        self.steamUsername = steamUsername
    }

    public static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("settings.json")
    }

    public static func load(from url: URL = fileURL) -> EasyPlaySettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(EasyPlaySettings.self, from: data) else {
            return EasyPlaySettings()
        }
        return settings
    }

    public func save(to url: URL = fileURL) throws {
        try AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
