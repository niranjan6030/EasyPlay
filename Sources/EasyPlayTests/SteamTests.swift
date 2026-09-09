import Foundation
import EasyPlayKit

/// Steam reports its own state in `appmanifest_*.acf`. Reading it correctly is
/// what stops EasyPlay declaring a half-downloaded 50 GB game "installed".
enum SteamTests {

    /// A real manifest's shape, trimmed to the fields EasyPlay reads.
    private static func manifest(stateFlags: Int, downloaded: Int64, toDownload: Int64) -> String {
        """
        "AppState"
        {
            "appid"        "1259980"
            "Universe"        "1"
            "name"        "RIDE 4"
            "StateFlags"        "\(stateFlags)"
            "installdir"        "RIDE 4"
            "BytesDownloaded"        "\(downloaded)"
            "BytesToDownload"        "\(toDownload)"
            "SizeOnDisk"        "53687091200"
            "InstalledDepots"
            {
                "1259981"
                {
                    "manifest"        "12345"
                    "size"        "999"
                }
            }
        }
        """
    }

    static func run() throws {
        Harness.suite("Steam manifest") {
            let done = SteamAppManifest.parse(manifest(stateFlags: 4, downloaded: 0, toDownload: 0))
            Harness.expect(done != nil, "a manifest parses")
            Harness.expectEqual(done?.appID, "1259980", "the app ID is read")
            Harness.expectEqual(done?.name, "RIDE 4", "the name is read")
            Harness.expectEqual(done?.installDirectory, "RIDE 4", "the install folder is read")
            Harness.expect(done?.isFullyInstalled == true, "StateFlags 4 means fully installed")

            // The case that matters: Steam keeps the installed flag set during an
            // update, so outstanding bytes still mean "not ready".
            let updating = SteamAppManifest.parse(manifest(stateFlags: 4, downloaded: 500, toDownload: 1000))
            Harness.expect(updating?.isFullyInstalled == false,
                           "an update in progress is not treated as installed despite the flag")
            Harness.expectEqual(updating?.downloadProgress, 0.5, "progress is reported while downloading")

            let downloading = SteamAppManifest.parse(manifest(stateFlags: 1026, downloaded: 250, toDownload: 1000))
            Harness.expect(downloading?.isFullyInstalled == false, "a downloading game is not installed")
            Harness.expectEqual(downloading?.downloadProgress, 0.25, "partial progress is reported")

            // Nested blocks must not leak into the top-level values.
            Harness.expect(done?.sizeOnDisk == 53687091200, "nested depot blocks don't corrupt parsing")

            Harness.expect(SteamAppManifest.parse("") == nil, "empty input parses to nothing")
            Harness.expect(SteamAppManifest.parse("not a manifest at all") == nil,
                           "junk input parses to nothing rather than a bogus manifest")
        }

        Harness.suite("Steam paths and routing") {
            let bottle = Bottle(name: "RIDE 4 test")
            let steamExe = SteamInstaller.steamExecutable(in: bottle)
            Harness.expect(steamExe.path.hasSuffix("drive_c/Program Files (x86)/Steam/steam.exe"),
                           "Steam is looked for where its installer puts it")
            Harness.expect(SteamAppManifest.manifestURL(appID: "1259980", in: bottle)
                            .path.hasSuffix("steamapps/appmanifest_1259980.acf"),
                           "the manifest path matches Steam's layout")

            // EasyPlay downloads Steam from Valve and nowhere else.
            Harness.expect(SteamInstaller.installerURL.host?.hasSuffix("steamstatic.com") == true,
                           "the installer comes from Valve's own CDN")

            if let ride4 = try? RecipeLibrary().recipe(id: "ride-4") {
                Harness.expect(ride4.install.kind == .steam, "RIDE 4 is routed through Steam")
                Harness.expect(ride4.install.steamAppID != nil, "and carries the app ID that routing needs")
            }
        }
    }
}
