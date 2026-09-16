import Foundation

/// A failure EasyPlay can recognise and explain.
public struct Diagnosis: Identifiable, Equatable {
    /// Something the app can offer to do about it, parsed from a recipe's
    /// `action` string.
    public enum Remedy: Equatable {
        /// Install a Windows runtime, e.g. `winetricks:vcrun2019`.
        case installWinetricksVerb(String)
        /// Switch this game to a different graphics translator.
        case switchGraphics(GraphicsBackend)
        /// Start Steam inside the bottle before retrying.
        case signInToSteam
        /// Rebuild the bottle from scratch.
        case recreateBottle

        public var buttonTitle: String {
            switch self {
            case .installWinetricksVerb(let verb): return "Install \(verb)"
            case .switchGraphics(let backend): return "Switch to \(backend.displayName)"
            case .signInToSteam: return "Sign in to Steam"
            case .recreateBottle: return "Rebuild bottle"
            }
        }

        public init?(action: String) {
            let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count > 1 ? parts[1] : nil) {
            case ("winetricks", let verb?): self = .installWinetricksVerb(verb)
            case ("graphics", let name?):
                guard let backend = GraphicsBackend(rawValue: name) else { return nil }
                self = .switchGraphics(backend)
            case ("steam", "signin"): self = .signInToSteam
            case ("bottle", "recreate"): self = .recreateBottle
            default: return nil
            }
        }
    }

    public let id: String
    public let title: String
    /// What went wrong and what to do, in plain English.
    public let explanation: String
    public let remedy: Remedy?
    /// The log line that triggered this, kept for the "show details" disclosure.
    public let evidence: String?

    public init(id: String, title: String, explanation: String,
                remedy: Remedy? = nil, evidence: String? = nil) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.remedy = remedy
        self.evidence = evidence
    }
}

/// Failure patterns common to every game, independent of any preset.
///
/// Wine's logs are written for Wine developers. Everything here exists to turn
/// one of those lines into a sentence a player can act on.
enum GlobalKnownIssues {
    struct Pattern {
        let id: String
        let regex: String
        let title: String
        let explanation: String
        let action: String?
    }

    static let all: [Pattern] = [
        Pattern(
            id: "missing-dll",
            regex: #"err:module:import_dll Library (\S+?) .*not found"#,
            title: "A Windows component is missing",
            explanation: "The game needs a Windows library that isn't in this bottle. EasyPlay can add the standard runtimes that supply it.",
            action: "winetricks:vcrun2019"
        ),
        Pattern(
            id: "missing-vcredist",
            regex: #"(MSVCP\d+|VCRUNTIME\d+|MSVCR\d+)\.dll"#,
            title: "Missing Visual C++ runtime",
            explanation: "Most Windows games need Microsoft's C++ runtime, which doesn't come with Wine. EasyPlay can install it into this bottle.",
            action: "winetricks:vcrun2019"
        ),
        Pattern(
            id: "missing-dotnet",
            regex: #"(mscoree|\.NET Framework|clr\.dll)"#,
            title: "Missing .NET Framework",
            explanation: "This program needs Microsoft .NET, which isn't installed in this bottle yet.",
            action: "winetricks:dotnet48"
        ),
        Pattern(
            id: "no-vulkan",
            regex: #"err:(winediag|vulkan):.*[Vv]ulkan|[Ww]ine was built without Vulkan|vulkan-1\.dll.*not found"#,
            title: "Vulkan isn't available",
            explanation: "DXVK needs Vulkan, and this Wine build has no Vulkan support at all. D3DMetal talks to Metal directly and doesn't need Vulkan, so use that instead.",
            action: "graphics:d3dMetal"
        ),
        Pattern(
            id: "d3d-device-failed",
            regex: #"(failed to create.*(d3d|device)|no adapters found|D3DERR)"#,
            title: "Graphics couldn't start",
            explanation: "The DirectX translation layer failed to create a graphics device. Switching translators usually gets past this.",
            action: "graphics:wineD3D"
        ),
        Pattern(
            id: "wrong-windows-version",
            regex: #"(requires Windows|unsupported operating system|GetVersionEx)"#,
            title: "The game expected a different Windows version",
            explanation: "This bottle reports a Windows version the game doesn't accept. Changing the reported version in the preset usually fixes it.",
            action: nil
        ),
        Pattern(
            id: "needs-32bit",
            regex: #"(16-bit|not a valid Win32 application|Bad EXE format)"#,
            title: "This program isn't 64-bit",
            explanation: "The bottle is 64-bit only, and this program needs 32-bit Windows. A 32-bit bottle is needed instead.",
            action: "bottle:recreate"
        ),
        Pattern(
            id: "anti-cheat",
            regex: #"(EasyAntiCheat|BattlEye|Vanguard|vgk\.sys)"#,
            title: "Blocked by anti-cheat",
            explanation: "This game uses anti-cheat software that runs inside the Windows kernel. Wine can't provide that, so the game can't run on a Mac — and bypassing it risks your account.",
            action: nil
        ),
        Pattern(
            id: "steam-client-required",
            regex: #"(steamclient|Steam).*(not running|failed to initial|SteamAPI_Init)|SteamAPI_RestartAppIfNecessary"#,
            title: "This game needs the Steam client running",
            explanation: "Some games refuse to start unless the Steam client is running alongside them. The Windows Steam client can't sign in under the free Wine builds available for macOS right now, so EasyPlay can't provide it for this game. If there's a Mac version, get that; otherwise CrossOver can run the Steam client.",
            action: nil
        ),
        Pattern(
            id: "wine-crash",
            regex: #"Unhandled exception code|Unhandled page fault|Assertion failed:|err:seh:NtRaiseException|invalid frame"#,
            title: "The game crashed",
            explanation: "The game started and then crashed inside Windows compatibility. That is usually the engine rather than the game: 32-bit games need the modern Wine engine, and 64-bit DirectX games need the Game Porting Toolkit. EasyPlay picks by the game's architecture, so if this keeps happening the other engine is worth a try.",
            action: nil
        ),
        Pattern(
            id: "out-of-disk",
            regex: #"(No space left on device|ENOSPC|disk full)"#,
            title: "Out of disk space",
            explanation: "The Mac ran out of space partway through. Free some up and try again.",
            action: nil
        ),
    ]
}
