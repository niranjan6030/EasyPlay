import Foundation
import EasyPlayKit

enum ExecutableFinderTests {

    private static func matches(_ glob: String, _ path: String) -> Bool {
        guard let regex = ExecutableFinder.regex(forGlob: glob) else { return false }
        return regex.firstMatch(in: path, options: [], range: NSRange(path.startIndex..., in: path)) != nil
    }

    static func run() throws {
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
