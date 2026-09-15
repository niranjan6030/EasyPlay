import Foundation

/// Reads SteamCMD's console output.
///
/// Kept separate from the code that runs SteamCMD so every rule here can be
/// tested against real output lines, without a network or a Steam account.
public enum SteamCMDOutput {

    public struct Progress: Equatable {
        /// Steam's update-state flags, e.g. 0x61 while downloading.
        public let state: String
        public let percent: Double
        public let bytesDone: Int64
        public let bytesTotal: Int64
    }

    /// Something SteamCMD reported that ends the operation.
    public enum Failure: Equatable {
        /// No cached login, or the cached one was rejected.
        case needsSignIn
        /// The account doesn't own the app. Free games still need adding to
        /// the account once.
        case notOwned
        case diskFull
        case rateLimited
        case other(String)

        public var explanation: String {
            switch self {
            case .needsSignIn:
                return "Steam needs you to sign in again. Press Sign in to Steam, enter your details in the window that opens, then try the install again."
            case .notOwned:
                return "This Steam account doesn't own the game yet. For a free game, open its Steam store page and press Play Game or Add to Library once, then try again."
            case .diskFull:
                return "There isn't enough free space for this download. Free some space and try again — Steam resumes where it stopped."
            case .rateLimited:
                return "Steam is refusing sign-ins for a moment because there were several attempts in a row. Wait about 15 minutes and try again."
            case .other(let detail):
                return "Steam reported a problem: \(detail)"
            }
        }
    }

    /// `Update state (0x61) downloading, progress: 67.07 (43359536 / 64647928)`
    public static func progress(in line: String) -> Progress? {
        let pattern = #"Update state \((0x[0-9a-fA-F]+)\)[^,]*, progress: ([0-9.]+) \(([0-9]+) / ([0-9]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let state = Range(m.range(at: 1), in: line),
              let pct = Range(m.range(at: 2), in: line),
              let done = Range(m.range(at: 3), in: line),
              let total = Range(m.range(at: 4), in: line) else { return nil }
        return Progress(state: String(line[state]),
                        percent: Double(line[pct]) ?? 0,
                        bytesDone: Int64(line[done]) ?? 0,
                        bytesTotal: Int64(line[total]) ?? 0)
    }

    /// `Success! App '1007' fully installed.`
    public static func isSuccess(_ line: String, appID: String) -> Bool {
        line.contains("Success! App '\(appID)' fully installed")
    }

    /// True once SteamCMD confirms a login, cached or fresh.
    public static func isSignedIn(_ line: String) -> Bool {
        line.contains("Logged in OK") || line.contains("Waiting for user info...OK")
    }

    /// Classifies a line that means the operation cannot succeed.
    public static func failure(in line: String) -> Failure? {
        let lower = line.lowercased()

        // With no cached credentials SteamCMD asks for a password or a Steam
        // Guard code. EasyPlay never answers those prompts — it sends the user
        // to sign in themselves.
        if lower.hasPrefix("password:") || lower.contains("steam guard code:")
            || lower.contains("two-factor code:")
            || lower.contains("invalid password")
            || lower.contains("cached credentials not found")
            || lower.contains("account logon denied")
            || lower.contains("login failure") && !lower.contains("rate limit") {
            return .needsSignIn
        }
        if lower.contains("rate limit") || lower.contains("too many login failures") {
            return .rateLimited
        }
        if lower.contains("no subscription") {
            return .notOwned
        }
        if lower.contains("not enough disk space") || lower.contains("disk write failure") {
            return .diskFull
        }
        if lower.hasPrefix("error! ") {
            return .other(line.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
