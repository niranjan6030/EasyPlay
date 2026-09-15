import Foundation

/// Steam's own record of an installed game.
///
/// Steam writes `steamapps/appmanifest_<appid>.acf` for every game it installs,
/// in Valve's KeyValues format. Reading it is how EasyPlay knows whether a
/// download has finished — far more reliable than watching for files to appear,
/// because a partially downloaded game has plenty of files and none of them mean
/// it is ready.
public struct SteamAppManifest: Equatable {
    public let appID: String
    public let name: String?
    /// Folder under `steamapps/common` holding the game.
    public let installDirectory: String?
    public let stateFlags: Int
    public let bytesDownloaded: Int64
    public let bytesToDownload: Int64
    public let sizeOnDisk: Int64

    /// Bit 2 of `StateFlags` is Valve's "fully installed" flag.
    private static let fullyInstalledFlag = 4

    public var isFullyInstalled: Bool {
        guard stateFlags & Self.fullyInstalledFlag != 0 else { return false }
        // A game mid-update keeps the installed flag set, so outstanding bytes
        // still mean "not ready".
        return bytesToDownload == 0 || bytesDownloaded >= bytesToDownload
    }

    /// 0-1 while downloading, nil when Steam hasn't reported sizes yet.
    public var downloadProgress: Double? {
        guard bytesToDownload > 0 else { return isFullyInstalled ? 1 : nil }
        return min(1, Double(bytesDownloaded) / Double(bytesToDownload))
    }

    /// Where SteamCMD leaves the manifest: `steamapps/` inside the directory
    /// the game was installed into.
    public static func manifestURL(appID: String, installDirectory: URL) -> URL {
        installDirectory
            .appendingPathComponent("steamapps", isDirectory: true)
            .appendingPathComponent("appmanifest_\(appID).acf")
    }

    public static func load(appID: String, installDirectory: URL) -> SteamAppManifest? {
        let url = manifestURL(appID: appID, installDirectory: installDirectory)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, fallbackAppID: appID)
    }

    /// Parses the flat key/value pairs out of a KeyValues document.
    ///
    /// Only the top-level `AppState` fields are needed, and every one of them is
    /// a quoted string on its own line, so a full KeyValues parser would be
    /// more machinery than the job requires. Nested blocks are skipped by depth.
    public static func parse(_ text: String, fallbackAppID: String = "") -> SteamAppManifest? {
        var values: [String: String] = [:]
        var depth = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" { depth += 1; continue }
            if line == "}" { depth -= 1; continue }
            // Depth 1 is inside "AppState"; anything deeper is a sub-block such
            // as InstalledDepots, which we don't need.
            guard depth <= 1 else { continue }

            let parts = line.components(separatedBy: "\"").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard parts.count >= 2 else { continue }
            values[parts[0].lowercased()] = parts[1]
        }

        guard !values.isEmpty else { return nil }
        let appID = values["appid"] ?? fallbackAppID
        guard !appID.isEmpty else { return nil }

        return SteamAppManifest(
            appID: appID,
            name: values["name"],
            installDirectory: values["installdir"],
            stateFlags: Int(values["stateflags"] ?? "") ?? 0,
            bytesDownloaded: Int64(values["bytesdownloaded"] ?? "") ?? 0,
            bytesToDownload: Int64(values["bytestodownload"] ?? "") ?? 0,
            sizeOnDisk: Int64(values["sizeondisk"] ?? "") ?? 0
        )
    }
}
