import Foundation
import EasyPlayKit

/// The probe answers "which translator is *really* loaded", so its matching
/// rules are checked against realistic library lists rather than a live game.
enum GraphicsProbeTests {
    private static let gptkPaths: Set<String> = [
        "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/external/D3DMetal.framework/D3DMetal",
        "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/external/libd3dshared.dylib",
        "/System/Library/Frameworks/Metal.framework/Versions/A/Metal",
        "/System/Library/Extensions/AGXMetalG16X.bundle/Contents/MacOS/AGXMetalG16X",
        "/usr/lib/libSystem.B.dylib",
    ]

    static func run() throws {
        Harness.suite("Graphics probe") {
            let probe = GraphicsProbe()

            let gptk = probe.makeReport(libraries: gptkPaths)
            Harness.expect(gptk.translator == .d3dMetal,
                           "D3DMetal is detected from the loaded framework")
            Harness.expect(gptk.usingMetal, "Metal is reported as active")
            Harness.expectEqual(gptk.gpuDriver, "AGXMetalG16X", "the GPU driver bundle is named")

            let dxvk = probe.makeReport(libraries: [
                "/Users/x/Bottles/b/drive_c/windows/system32/dxvk_d3d11.dll",
                "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/libMoltenVK.dylib",
                "/System/Library/Frameworks/Metal.framework/Versions/A/Metal",
            ])
            Harness.expect(dxvk.translator == .dxvk, "DXVK is detected from MoltenVK and its DLLs")

            // WineD3D reaches the GPU through OpenGL, so no Metal translator
            // framework appears at all.
            let wined3d = probe.makeReport(libraries: [
                "/System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL",
                "/usr/lib/libSystem.B.dylib",
            ])
            Harness.expect(wined3d.translator == .wineD3D, "the OpenGL fallback is recognised")

            // The false positive that made the probe untrustworthy: Wine Staging
            // maps MoltenVK at startup whether or not anything uses Vulkan, and
            // TrackMania — rendering through wined3d — was reported as DXVK.
            let stagingWithVulkan = probe.makeReport(libraries: [
                "/Users/x/Runtimes/Wine Staging.app/Contents/Resources/wine/lib/libMoltenVK.dylib",
                "/Users/x/Runtimes/Wine Staging.app/Contents/Resources/wine/lib/wine/x86_64-unix/wined3d.so",
                "/System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL",
                "/System/Library/Extensions/AGXMetalG16G.bundle/Contents/MacOS/AGXMetalG16G",
            ])
            Harness.expect(stagingWithVulkan.translator == .wineD3D,
                           "MoltenVK alongside wined3d is WineD3D, not DXVK")
            Harness.expect(stagingWithVulkan.usingMetal,
                           "OpenGL still reaches the GPU through Metal")

            // A process that has not started rendering must not be reported as
            // using anything — guessing here would defeat the point of probing.
            let notYet = probe.makeReport(libraries: ["/usr/lib/libSystem.B.dylib"])
            Harness.expect(notYet.translator == nil, "no translator is claimed when none is loaded")
            Harness.expect(!notYet.usingMetal, "and Metal is not claimed either")
            Harness.expect(notYet.summary.contains("No DirectX translation layer"),
                           "the summary says so plainly")

            // D3DMetal must win over MoltenVK: GPTK ships libMoltenVK.dylib in the
            // same lib directory, so a naive DXVK match would misreport every
            // D3DMetal session as DXVK.
            var mixed = gptkPaths
            mixed.insert("/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/libMoltenVK.dylib")
            Harness.expect(probe.makeReport(libraries: mixed).translator == .d3dMetal,
                           "D3DMetal outranks the MoltenVK that ships beside it")
        }
    }
}
