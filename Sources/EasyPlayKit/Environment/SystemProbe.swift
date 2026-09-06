import Foundation

/// Facts about the Mac itself that decide whether Windows games can run at all.
public struct SystemInfo {
    public enum Architecture: String {
        case appleSilicon = "arm64"
        case intel = "x86_64"
        case unknown
    }

    public let architecture: Architecture
    public let macOSVersion: OperatingSystemVersion
    public let chipName: String
    public let rosettaInstalled: Bool
    public let freeDiskBytes: Int64

    public var macOSVersionString: String {
        "\(macOSVersion.majorVersion).\(macOSVersion.minorVersion).\(macOSVersion.patchVersion)"
    }

    public var freeDiskGB: Double {
        Double(freeDiskBytes) / 1_000_000_000
    }

    /// Windows game binaries are x86-64. On Apple Silicon they only run because
    /// Rosetta 2 translates them, so its absence is a hard stop, not a warning.
    public var needsRosetta: Bool { architecture == .appleSilicon }

    public var canRunWindowsBinaries: Bool {
        switch architecture {
        case .intel: return true
        case .appleSilicon: return rosettaInstalled
        case .unknown: return false
        }
    }
}

public struct SystemProbe {
    private let runner: ProcessRunner
    private let fileManager: FileManager

    public init(runner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func probe() -> SystemInfo {
        SystemInfo(
            architecture: detectArchitecture(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Unknown",
            rosettaInstalled: detectRosetta(),
            freeDiskBytes: freeDiskBytes()
        )
    }

    /// `uname` reports the *translated* architecture if we were launched under
    /// Rosetta, so we ask sysctl whether translation is active and correct for it.
    private func detectArchitecture() -> SystemInfo.Architecture {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        if machine == "arm64" { return .appleSilicon }
        if machine == "x86_64" {
            // sysctl.proc_translated == 1 means this very process is emulated,
            // which means the hardware underneath is actually Apple Silicon.
            return isProcessTranslated() ? .appleSilicon : .intel
        }
        return .unknown
    }

    private func isProcessTranslated() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }

    /// Rosetta 2 is present when its runtime directory has been installed. We
    /// check the on-disk marker rather than `pgrep oahd`, because the daemon is
    /// launched on demand and may legitimately not be running yet.
    private func detectRosetta() -> Bool {
        let markers = [
            "/Library/Apple/usr/libexec/oah/libRosettaRuntime",
            "/Library/Apple/usr/share/rosetta/rosetta",
        ]
        return markers.contains { fileManager.fileExists(atPath: $0) }
    }

    private func freeDiskBytes() -> Int64 {
        let home = fileManager.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return available
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
