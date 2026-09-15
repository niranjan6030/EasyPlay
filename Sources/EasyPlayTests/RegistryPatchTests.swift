import Foundation
import EasyPlayKit

/// A preset's registry changes are applied as one `.reg` import instead of a
/// Wine launch per value, so the file has to be exactly right.
enum RegistryPatchTests {
    static func run() throws {
        Harness.suite("Registry batching") {
            guard let ride4 = try? RecipeLibrary().recipe(id: "ride-4") else {
                Harness.expect(false, "the RIDE 4 preset loads"); return
            }
            let patch = RegistryPatch.forRecipe(ride4)
            let text = patch.regFileContents

            Harness.expect(text.hasPrefix("Windows Registry Editor Version 5.00"),
                           "the file carries the header regedit requires")
            Harness.expect(text.contains(#"[HKEY_CURRENT_USER\Software\Wine]"#),
                           "the Windows version key is present")
            Harness.expect(text.contains(#""Version"="win10""#), "the Windows version is set")
            Harness.expect(text.contains(#""RetinaMode"="y""#), "Retina mode is set for a preset that wants it")
            Harness.expect(text.contains(#""d3d11"="builtin""#), "DLL overrides are included")

            // Each key appears once, however many values it holds — a key
            // repeated per value would still import, but hides mistakes.
            let overrideHeaders = text.components(separatedBy: #"[HKEY_CURRENT_USER\Software\Wine\DllOverrides]"#).count - 1
            Harness.expectEqual(overrideHeaders, 1, "values under one key are grouped under a single header")

            var p = RegistryPatch()
            p.set("K", "a", "1")
            p.set("K", "a", "2")
            Harness.expectEqual(p.values.count, 1, "setting a value twice keeps only the latest")
            Harness.expectEqual(p.values.first?.data, "2", "and the latest wins")

            var q = RegistryPatch()
            q.set("K", #"path"#, #"C:\Games\"quoted""#)
            Harness.expect(q.regFileContents.contains(#""path"="C:\\Games\\\"quoted\"""#),
                           "backslashes and quotes are escaped the way .reg files require")

            Harness.expect(RegistryPatch().isEmpty, "an empty patch reports itself empty")
        }
    }
}
