import Foundation
import EasyPlayKit

/// Architecture detection matters because of a constraint that is otherwise
/// invisible: D3DMetal is 64-bit only, and Wine hides the fallback.
enum WindowsExecutableTests {

    private static func backend(_ kind: WineBackend.Kind = .gamePortingToolkit) -> WineBackend {
        WineBackend(kind: kind,
                    binDirectory: URL(fileURLWithPath: "/tmp/wine/bin"),
                    version: "7.7",
                    bundledTranslators: [.d3dMetal, .wineD3D])
    }

    /// Builds the smallest file that is still a valid PE header for `machine`.
    private static func writePE(machine: UInt16, to url: URL) throws {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0] = 0x4D; bytes[1] = 0x5A                     // "MZ"
        bytes[0x3C] = 0x80                                    // e_lfanew -> 0x80
        bytes[0x80] = 0x50; bytes[0x81] = 0x45                // "PE"
        bytes[0x82] = 0x00; bytes[0x83] = 0x00
        bytes[0x84] = UInt8(machine & 0xFF)                   // COFF machine, LE
        bytes[0x85] = UInt8(machine >> 8)
        try Data(bytes).write(to: url)
    }

    static func run() throws {
        Harness.suite("Windows executable architecture") {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("easyplay-pe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            do {
                let x86 = directory.appendingPathComponent("game32.exe")
                let x64 = directory.appendingPathComponent("game64.exe")
                let junk = directory.appendingPathComponent("notanexe.exe")
                try writePE(machine: 0x014c, to: x86)
                try writePE(machine: 0x8664, to: x64)
                try Data("this is not a PE file".utf8).write(to: junk)

                Harness.expect(WindowsExecutable.architecture(of: x86) == .x86,
                               "a 32-bit PE is identified")
                Harness.expect(WindowsExecutable.architecture(of: x64) == .x64,
                               "a 64-bit PE is identified")
                Harness.expect(WindowsExecutable.architecture(of: junk) == .unknown,
                               "a non-PE file is not guessed at")
                Harness.expect(WindowsExecutable.architecture(of: directory.appendingPathComponent("missing.exe")) == .unknown,
                               "a missing file reports unknown rather than trapping")
            } catch {
                Harness.expect(false, "PE fixtures can be written: \(error)")
            }

            // The finding that cost an entire benchmark download: Unigine Heaven
            // 4.0 ships only a 32-bit engine, so it can never reach D3DMetal.
            let gptk = backend()
            Harness.expect(!gptk.supports(.d3dMetal, for: .x86),
                           "D3DMetal is refused for 32-bit programs")
            Harness.expect(gptk.supports(.d3dMetal, for: .x64),
                           "D3DMetal is available to 64-bit programs")
            Harness.expect(!gptk.supports(.dxvk, for: .x86),
                           "DXVK is 64-bit only here too")
            Harness.expect(gptk.supports(.wineD3D, for: .x86),
                           "the OpenGL fallback works for anything, which is why Wine silently uses it")

            // And the preflight turns that into something a user can read.
            let launcher = GameLauncher(backend: gptk)
            let x86Again = directory.appendingPathComponent("game32.exe")
            if let recipe = try? RecipeLibrary().recipe(id: "unigine-heaven") {
                let diagnoses = launcher.preflight(executable: x86Again, recipe: recipe)
                Harness.expectEqual(diagnoses.count, 1,
                                    "a 32-bit program asking for D3DMetal is flagged before launch")
                Harness.expect(diagnoses.first?.remedy == .switchGraphics(.wineD3D),
                               "and the offered fix is the translator that will actually work")
            }
        }
    }
}
