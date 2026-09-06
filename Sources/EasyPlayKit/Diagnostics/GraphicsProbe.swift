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

        public var summary: String {
            guard let translator else {
                return "No DirectX translation layer detected in the running process."
            }
            let metal = usingMetal ? ", rendering through Metal" : ", but Metal is not loaded"
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

        let d3dMetal = matches("D3DMetal") + matches("libd3dshared")
        let dxvk = matches("dxvk") + matches("libMoltenVK") + matches("libvulkan")
        let metal = matches("/Metal.framework/") + matches("MetalPerformance")
        let driver = matches("AGXMetal").first ?? matches("AppleIntelGraphics").first

        let translator: GraphicsBackend?
        if !d3dMetal.isEmpty {
            translator = .d3dMetal
        } else if !dxvk.isEmpty {
            translator = .dxvk
        } else if !matches("wined3d").isEmpty || !matches("libGL").isEmpty || !matches("OpenGL.framework").isEmpty {
            translator = .wineD3D
        } else {
            translator = nil
        }

        return Report(
            translator: translator,
            usingMetal: !metal.isEmpty || driver != nil,
            gpuDriver: driver.map { URL(fileURLWithPath: $0).lastPathComponent },
            processIDs: pids,
            evidence: Array((d3dMetal + dxvk + metal).prefix(12))
        )
    }
}
