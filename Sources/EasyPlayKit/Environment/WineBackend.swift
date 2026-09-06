import Foundation

/// A Wine distribution installed on this Mac.
///
/// EasyPlay never builds or patches Wine — it locates one that is already
/// installed and drives its binaries. Each case knows where its `wine64` lives
/// and which graphics translators that build ships with.
public struct WineBackend: Identifiable, Equatable {

    public enum Kind: String, Codable, CaseIterable {
        /// Apple's Game Porting Toolkit, packaged by Gcenx. A CrossOver-derived
        /// Wine bundled with D3DMetal. The recommended backend on Apple Silicon.
        case gamePortingToolkit
        /// An official WineHQ build (stable / devel / staging).
        case wineHQ
        /// A Wine on PATH that we didn't recognise, or one the user pointed us at.
        case custom

        public var displayName: String {
            switch self {
            case .gamePortingToolkit: return "Game Porting Toolkit"
            case .wineHQ: return "WineHQ"
            case .custom: return "Custom Wine"
            }
        }
    }

    public let kind: Kind
    /// Directory containing `wine64`, `wineserver`, `wineboot`, …
    public let binDirectory: URL
    public let version: String
    /// Graphics translators this build ships with out of the box.
    public let bundledTranslators: Set<GraphicsBackend>

    public init(kind: Kind, binDirectory: URL, version: String,
                bundledTranslators: Set<GraphicsBackend>) {
        self.kind = kind
        self.binDirectory = binDirectory
        self.version = version
        self.bundledTranslators = bundledTranslators
    }

    public var id: String { binDirectory.path }

    public var wine64: URL { binDirectory.appendingPathComponent("wine64") }
    public var wineserver: URL { binDirectory.appendingPathComponent("wineserver") }

    public var displayName: String { "\(kind.displayName) \(version)" }

    /// Where this backend keeps the Mac-side libraries its DirectX translation
    /// depends on. For Game Porting Toolkit that is `D3DMetal.framework` and
    /// `libd3dshared.dylib`, which the patched `d3d11`/`dxgi` DLLs load at
    /// runtime — so this directory has to be on the dynamic loader's path.
    public var externalLibraryDirectory: URL? {
        switch kind {
        case .gamePortingToolkit:
            // …/Resources/wine/bin -> …/Resources/wine/lib/external
            return binDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("lib/external", isDirectory: true)
        case .wineHQ, .custom:
            return nil
        }
    }

    /// On Game Porting Toolkit the *built-in* d3d11 and dxgi DLLs are Apple's
    /// D3DMetal implementation, so "builtin" and "D3DMetal" mean the same thing
    /// there. WineD3D is only separately selectable on stock WineHQ builds.
    public var builtinTranslator: GraphicsBackend {
        kind == .gamePortingToolkit ? .d3dMetal : .wineD3D
    }
}

/// How Direct3D calls reach the Mac GPU.
public enum GraphicsBackend: String, Codable, CaseIterable {
    /// Apple's D3DMetal — DirectX 11/12 straight to Metal. Ships inside GPTK and
    /// is what CrossOver uses for modern titles. Fastest option on Apple Silicon.
    case d3dMetal
    /// DXVK — DirectX 9/10/11 to Vulkan, reaching Metal through MoltenVK. The
    /// macOS fork is pinned at 1.10.3 and unmaintained, so it is an option rather
    /// than the default.
    case dxvk
    /// Wine's own built-in Direct3D-to-OpenGL translation. Slow, but it works
    /// when nothing else does, which makes it a useful fallback.
    case wineD3D

    public var displayName: String {
        switch self {
        case .d3dMetal: return "D3DMetal (Apple)"
        case .dxvk: return "DXVK (Vulkan via MoltenVK)"
        case .wineD3D: return "WineD3D (built-in)"
        }
    }

    public var summary: String {
        switch self {
        case .d3dMetal:
            return "Translates DirectX 11 and 12 directly to Metal. Best performance on Apple Silicon."
        case .dxvk:
            return "Translates DirectX 9-11 to Vulkan, then to Metal. Useful for older titles."
        case .wineD3D:
            return "Wine's built-in translator. Slowest, but the most compatible fallback."
        }
    }
}
