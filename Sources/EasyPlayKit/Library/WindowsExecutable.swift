import Foundation

/// Reads the parts of a Windows PE header EasyPlay needs to make decisions.
///
/// This exists because of a constraint that is invisible until a game is already
/// installed and misbehaving: Apple's D3DMetal is a 64-bit-only library, so a
/// 32-bit Windows game cannot use it no matter what its preset asks for. Wine
/// falls back to its OpenGL renderer without saying so, and the result is a game
/// that starts, runs badly, and reports a graphics card that doesn't exist.
public enum WindowsExecutable {

    public enum Architecture: String {
        case x86
        case x64
        case arm64
        case unknown

        public var displayName: String {
            switch self {
            case .x86: return "32-bit"
            case .x64: return "64-bit"
            case .arm64: return "ARM64"
            case .unknown: return "unknown architecture"
            }
        }

        public var is64Bit: Bool { self == .x64 || self == .arm64 }
    }

    /// COFF machine types, from the PE specification.
    private static let machineTypes: [UInt16: Architecture] = [
        0x014c: .x86,
        0x8664: .x64,
        0xAA64: .arm64,
    ]

    /// Reads the COFF machine field without loading the whole file — game
    /// executables can be hundreds of megabytes.
    public static func architecture(of url: URL) -> Architecture {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }

        func readUInt16(at offset: UInt64) -> UInt16? {
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: 2), data.count == 2 else { return nil }
            return UInt16(data[data.startIndex]) | (UInt16(data[data.startIndex + 1]) << 8)
        }

        func readUInt32(at offset: UInt64) -> UInt32? {
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return nil }
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }

        // "MZ" — every PE file starts with a DOS stub.
        guard readUInt16(at: 0) == 0x5A4D else { return .unknown }
        // e_lfanew at 0x3C points at the PE header.
        guard let peOffset = readUInt32(at: 0x3C),
              readUInt32(at: UInt64(peOffset)) == 0x00004550 else { return .unknown }  // "PE\0\0"
        // The COFF machine field immediately follows the signature.
        guard let machine = readUInt16(at: UInt64(peOffset) + 4) else { return .unknown }

        return machineTypes[machine] ?? .unknown
    }
}

public extension WineBackend {
    /// Can this backend serve `translator` to a program of this architecture?
    ///
    /// Game Porting Toolkit ships D3DMetal as an x86_64-only framework, with no
    /// 32-bit host-side Direct3D module at all, so 32-bit programs silently get
    /// Wine's OpenGL renderer instead.
    func supports(_ translator: GraphicsBackend, for architecture: WindowsExecutable.Architecture) -> Bool {
        switch translator {
        case .wineD3D:
            return true
        case .d3dMetal:
            // D3DMetal is an x86_64-only framework that only this engine carries.
            return kind == .gamePortingToolkit && architecture.is64Bit
        case .dxvk:
            return architecture.is64Bit
        }
    }
}
