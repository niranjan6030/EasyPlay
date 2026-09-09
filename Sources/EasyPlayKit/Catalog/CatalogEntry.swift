import Foundation

/// Anti-cheat systems, and whether Wine can survive them.
public enum AntiCheat: String, Codable, CaseIterable {
    case easyAntiCheat
    case battlEye
    case vanguard
    case ricochet
    case mhyprot
    /// Valve Anti-Cheat — server-side and user-space, so it is not a blocker.
    case vac
    case denuvo

    public var displayName: String {
        switch self {
        case .easyAntiCheat: return "Easy Anti-Cheat"
        case .battlEye: return "BattlEye"
        case .vanguard: return "Riot Vanguard"
        case .ricochet: return "RICOCHET"
        case .mhyprot: return "mhyprot"
        case .vac: return "VAC"
        case .denuvo: return "Denuvo"
        }
    }

    /// Kernel-level anti-cheat needs a Windows kernel driver. Wine implements
    /// Windows' user space, not its kernel, so these can never work — this is a
    /// structural fact, not a bug waiting to be fixed.
    public var isKernelLevel: Bool {
        switch self {
        case .easyAntiCheat, .battlEye, .vanguard, .ricochet, .mhyprot: return true
        case .vac, .denuvo: return false
        }
    }

    public var explanation: String {
        switch self {
        case .vanguard:
            return "Riot Vanguard loads as a Windows kernel driver at boot. Wine has no Windows kernel for it to load into."
        case .easyAntiCheat:
            return "Easy Anti-Cheat runs as a Windows kernel driver. Its Linux support (used on Steam Deck) does not extend to macOS, and CrossOver does not support it."
        case .battlEye:
            return "BattlEye runs as a Windows kernel driver. Its Linux support does not extend to macOS."
        case .ricochet:
            return "RICOCHET is a Windows kernel-level driver with no Linux or macOS support."
        case .mhyprot:
            return "This game installs a Windows kernel driver for anti-cheat, which Wine cannot provide."
        case .vac:
            return "VAC runs in user space and on the server, so it does not block Wine by itself."
        case .denuvo:
            return "Denuvo is copy protection rather than kernel anti-cheat. It sometimes works under Wine and sometimes doesn't."
        }
    }
}

/// Where a game is sold, so EasyPlay can send you to the real storefront.
public struct Storefront: Codable, Equatable {
    public enum Kind: String, Codable {
        case steam, gog, epic, publisher

        public var displayName: String {
            switch self {
            case .steam: return "Steam"
            case .gog: return "GOG"
            case .epic: return "Epic Games Store"
            case .publisher: return "the publisher's site"
            }
        }
    }

    public let kind: Kind
    public let id: String?
    public let url: String?

    /// The official store page. EasyPlay only ever points at the real
    /// storefront — it does not source games from anywhere else.
    public var storeURL: URL? {
        if let url { return URL(string: url) }
        guard let id else { return nil }
        switch kind {
        case .steam: return URL(string: "https://store.steampowered.com/app/\(id)/")
        case .gog: return URL(string: "https://www.gog.com/game/\(id)")
        case .epic: return URL(string: "https://store.epicgames.com/p/\(id)")
        case .publisher: return nil
        }
    }
}

/// What EasyPlay knows about one game.
///
/// This is knowledge, not configuration — a `Recipe` says *how* to run a game,
/// a `CatalogEntry` says *whether* you should bother trying. Most entries have
/// no recipe, and that is the point: answering "no, don't buy this" correctly is
/// worth more than answering "yes" vaguely.
public struct CatalogEntry: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    /// Alternative spellings people actually type.
    public let aliases: [String]
    public let publisher: String?
    public let store: Storefront?

    /// The publisher ships a macOS build. The best possible answer, because it
    /// means EasyPlay isn't needed at all.
    public let macNative: Bool
    public let antiCheat: AntiCheat?
    public let graphicsAPI: [String]
    /// A shipped preset, when one exists.
    public let presetID: String?

    /// What EasyPlay is willing to claim, and on what basis.
    public let verdict: CompatibilityRating
    public let source: String
    public let lastReviewed: String
    public let notes: [String]

    /// Every name this entry should answer to.
    public var searchableNames: [String] { [title] + aliases }
}
