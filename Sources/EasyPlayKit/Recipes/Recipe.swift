import Foundation

/// How well a game is known to run, in the user's language rather than ours.
public enum CompatibilityRating: String, Codable, CaseIterable {
    case runsGreat
    case runsOK
    case untested
    case notSupported

    public var displayName: String {
        switch self {
        case .runsGreat: return "Runs Great"
        case .runsOK: return "Runs OK"
        case .untested: return "Untested"
        case .notSupported: return "Not Supported"
        }
    }

    public var summary: String {
        switch self {
        case .runsGreat: return "Plays well with the settings in this preset."
        case .runsOK: return "Playable, with some rough edges. See the notes."
        case .untested: return "Nobody has verified this preset yet. It may or may not work."
        case .notSupported: return "This game cannot run on a Mac. EasyPlay won't attempt it."
        }
    }

    public var isPlayable: Bool { self != .notSupported }
}

/// Why a game is refused outright, so the UI can explain rather than just fail.
public enum UnsupportedReason: String, Codable {
    /// Kernel-level anti-cheat (EasyAntiCheat, BattlEye, Vanguard) needs a Windows
    /// kernel driver. There is no Wine workaround, now or in the foreseeable
    /// future — attempting it wastes the user's time and can flag their account.
    case kernelAntiCheat
    case requiresDirectX12Ultimate
    case knownBroken

    public var explanation: String {
        switch self {
        case .kernelAntiCheat:
            return "This game uses anti-cheat software that runs inside the Windows kernel. Wine cannot provide that, so the game will never launch on a Mac. Trying anyway can also get your account flagged."
        case .requiresDirectX12Ultimate:
            return "This game needs DirectX 12 features that Apple's translation layer doesn't implement yet."
        case .knownBroken:
            return "This game is known to fail on macOS for reasons no preset can work around."
        }
    }
}

/// A per-game "recipe": everything EasyPlay needs to turn a bare Wine prefix into
/// one that runs this specific game.
///
/// This is the heart of the project. Wine can already run these games; what it
/// cannot do is remember *how*. A recipe is that memory, in a form that can be
/// version-controlled, diffed, and shared.
public struct Recipe: Codable, Identifiable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let title: String
    public let publisher: String?
    /// Filename fragments that identify this game's installer, beyond its title.
    /// Real installers are named things like `7z2409-x64.exe`, which contains no
    /// recognisable product name, so presets declare their own aliases.
    /// Matching is case-insensitive and ignores punctuation.
    public let installerPatterns: [String]?
    public let compatibility: Compatibility
    public let requires: Requirements
    public let bottle: BottleSettings
    public let graphics: GraphicsSettings
    /// Wine DLL override table, e.g. `["d3d11": "native,builtin"]`.
    public let dllOverrides: [String: String]
    /// Environment variables exported for both the installer and the game.
    public let environment: [String: String]
    /// Winetricks verbs applied after the bottle is created, in order.
    public let winetricks: [String]
    public let install: InstallPlan
    public let launch: LaunchPlan
    public let knownIssues: [KnownIssue]

    public struct Compatibility: Codable, Equatable {
        public let rating: CompatibilityRating
        public let unsupportedReason: UnsupportedReason?
        /// ISO date the rating was last confirmed.
        public let lastVerified: String?
        /// Where the rating came from, so a user can check it themselves.
        public let source: String?
        public let notes: [String]

        public init(rating: CompatibilityRating, unsupportedReason: UnsupportedReason? = nil,
                    lastVerified: String? = nil, source: String? = nil, notes: [String] = []) {
            self.rating = rating
            self.unsupportedReason = unsupportedReason
            self.lastVerified = lastVerified
            self.source = source
            self.notes = notes
        }
    }

    public struct Requirements: Codable, Equatable {
        /// Backend this recipe was tuned against. `nil` means any Wine will do.
        public let backend: WineBackend.Kind?
        public let rosetta: Bool
        public let diskGB: Int
    }

    public struct BottleSettings: Codable, Equatable {
        /// Wine's reported Windows version, e.g. "win10".
        public let windowsVersion: String
        /// "win64" or "win32".
        public let architecture: String
        public let retinaMode: Bool
        public let dpi: Int?
    }

    public struct GraphicsSettings: Codable, Equatable {
        public let backend: GraphicsBackend
        public let dxvk: DXVKSettings?

        public struct DXVKSettings: Codable, Equatable {
            public let version: String
            public let async: Bool
            public let showHUD: Bool
        }
    }

    public struct InstallPlan: Codable, Equatable {
        public enum Kind: String, Codable {
            /// Install the Steam client into the bottle, then the game through it.
            case steam
            /// Run a setup .exe the user supplies.
            case installerExecutable
            /// Mount a disc image, then run its setup.
            case discImage
            /// Already-installed game folder copied into the bottle.
            case existingFolder
        }

        public let kind: Kind
        public let steamAppID: String?
        /// Arguments passed to the installer executable, if any.
        public let installerArguments: [String]
        /// Shown to the user during the install step.
        public let hints: [String]
    }

    public struct LaunchPlan: Codable, Equatable {
        /// Glob, relative to the bottle's C: drive, locating the game executable.
        public let executableGlob: String
        public let arguments: [String]
        /// Run with the executable's own folder as the working directory. Many
        /// games load assets by relative path and fail without this.
        public let workingDirectoryFromExecutable: Bool
    }

    /// A failure pattern this game is known to produce, and what to do about it.
    public struct KnownIssue: Codable, Equatable, Identifiable {
        /// Regular expression matched against Wine's output.
        public let match: String
        public let title: String
        /// Plain-English explanation and fix.
        public let fix: String
        /// Machine-actionable remedy, e.g. "winetricks:vcrun2019".
        public let action: String?

        public var id: String { match }
    }
}
