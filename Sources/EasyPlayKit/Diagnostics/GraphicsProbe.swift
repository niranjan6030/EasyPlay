import Foundation

/// Reports which graphics translator a running game is *actually* using.
///
/// A recipe says which translator it wants, and Wine will silently fall back to
/// something slower if that one fails to initialise — the game still runs, just
/// badly, with nothing in the log to say why. This inspects the libraries a live
/// process has loaded and reports what is really happening, which is the
/// difference between "configured for D3DMetal" and "using D3DMetal".
public struct GraphicsProbe {

    public struct Report {
        /// The translator actually loaded, or nil if none was recognised.
        public let translator: GraphicsBackend?
        /// Apple's Metal framework is loaded, i.e. the GPU is being driven
        /// through Metal rather than a software path.
        public let usingMetal: Bool
        /// The GPU driver bundle, when one is loaded.
        public let gpuDriver: String?
        /// Process IDs the report was assembled from.
        public let processIDs: [Int32]
        /// The matched libraries, as evidence.
        public let evidence: [String]

        /// True once the whole chain is up: a translator *and* the GPU driver.
        /// Until then the picture is still forming and worth waiting for.
        public var isComplete: Bool { translator != nil && usingMetal }

        public var summary: String {
            guard let translator else {
                return "No DirectX translation layer detected in the running process."
            }
            let metal = usingMetal
                ? ", rendering through Metal on \(gpuDriver ?? "the GPU")"
                : ", but the GPU driver has not loaded yet"
            return "\(translator.displayName)\(metal)."
        }
    }

    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    /// Finds running processes whose command line mentions `executableName`.
    public func processIDs(forExecutableNamed executableName: String) -> [Int32] {
        guard let result = try? runner.run("/usr/bin/pgrep", ["-f", executableName], timeout: 20),
              result.succeeded else { return [] }
        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Inspects the libraries mapped into a running game.
    public func probe(executableNamed executableName: String) -> Report {
        let pids = processIDs(forExecutableNamed: executableName)
        guard !pids.isEmpty else {
            return Report(translator: nil, usingMetal: false, gpuDriver: nil,
                          processIDs: [], evidence: [])
        }

        var libraries: Set<String> = []
        for pid in pids {
            // lsof lists every file a process has mapped, which for a running
            // game includes each framework and dylib it loaded.
            guard let result = try? runner.run("/usr/sbin/lsof", ["-p", "\(pid)"], timeout: 60) else { continue }
            for line in result.standardOutput.split(whereSeparator: \.isNewline) {
                guard let path = line.split(separator: " ").last.map(String.init),
                      path.hasPrefix("/") else { continue }
                libraries.insert(path)
            }
        }

        return makeReport(libraries: libraries, pids: pids)
    }

    /// Split out from `probe` so the matching rules can be tested without a
    /// running game.
    public func makeReport(libraries: Set<String>, pids: [Int32] = []) -> Report {
        func matches(_ needle: String) -> [String] {
            libraries.filter { $0.localizedCaseInsensitiveContains(needle) }.sorted()
        }

        let d3dMetal = matches("D3DMetal") + matches("libd3dshared") + matches("metalirconverter")
        // DXVK's own DLLs are the only proof of DXVK. MoltenVK and libvulkan are
        // not: Wine Staging maps MoltenVK at startup whether or not anything
        // asks for Vulkan, and reporting that as "using DXVK" is how the probe
        // told us TrackMania ran on DXVK when it was really on WineD3D.
        let dxvk = matches("dxvk")
        let vulkan = matches("libMoltenVK") + matches("libvulkan")
        // Wine's own translator, and the OpenGL stack it renders through.
        let wineD3D = matches("wined3d") + matches("opengl32") + matches("libGL")
            + matches("OpenGL.framework")
        // Apple's own Metal.framework lives in the dyld shared cache and never
        // appears as a mapped file, so the GPU driver bundle is the reliable
        // signal that Metal is actually driving the GPU.
        let metal = matches("AGXMetal") + matches("metallib") + matches("/Metal.framework/")
        let driver = matches("AGXMetal").first ?? matches("AppleIntelGraphics").first

        // Ordered by how conclusive the evidence is. WineD3D is checked before
        // Vulkan because a process can have MoltenVK mapped and still be
        // rendering through wined3d — which is the common case on Wine Staging.
        let translator: GraphicsBackend?
        if !d3dMetal.isEmpty {
            translator = .d3dMetal
        } else if !dxvk.isEmpty {
            translator = .dxvk
        } else if !wineD3D.isEmpty {
            translator = .wineD3D
        } else if !vulkan.isEmpty {
            translator = .dxvk
        } else {
            translator = nil
        }

        return Report(
            translator: translator,
            usingMetal: !metal.isEmpty || driver != nil,
            gpuDriver: driver.map { URL(fileURLWithPath: $0).lastPathComponent },
            processIDs: pids,
            evidence: Array(Set(d3dMetal + dxvk + wineD3D + vulkan + metal)).sorted().prefix(12).map { $0 }
        )
    }
}
