import Foundation
import EasyPlayKit

/// SteamCMD speaks in console lines. These are real ones, captured from Valve's
/// macOS SteamCMD, so the parsing is tested against what it actually prints.
enum SteamCMDTests {
    static func run() throws {
        Harness.suite("SteamCMD output") {
            // Captured verbatim while downloading app 1007 on this Mac.
            let real = " Update state (0x61) downloading, progress: 67.07 (43359536 / 64647928)"
            let p = SteamCMDOutput.progress(in: real)
            Harness.expectEqual(p?.state, "0x61", "the update state is read")
            Harness.expectEqual(p?.percent, 67.07, "the percentage is read")
            Harness.expectEqual(p?.bytesDone, 43359536, "bytes downloaded are read")
            Harness.expectEqual(p?.bytesTotal, 64647928, "total bytes are read")

            Harness.expect(SteamCMDOutput.progress(in: " Update state (0x3) reconfiguring, progress: 0.00 (0 / 0)") != nil,
                           "the zero-byte reconfiguring phase still parses")
            Harness.expect(SteamCMDOutput.progress(in: "Loading Steam API...OK") == nil,
                           "unrelated lines are not mistaken for progress")

            Harness.expect(SteamCMDOutput.isSuccess("Success! App '1007' fully installed.", appID: "1007"),
                           "success is recognised")
            Harness.expect(!SteamCMDOutput.isSuccess("Success! App '1007' fully installed.", appID: "588430"),
                           "success for a different app is not counted")

            // The rule that keeps credentials out of EasyPlay: a password or
            // Steam Guard prompt is never answered — it means "go and sign in".
            for prompt in ["password: ", "Steam Guard code:", "Two-factor code:",
                           "FAILED (Invalid Password)", "Cached credentials not found."] {
                Harness.expect(SteamCMDOutput.failure(in: prompt) == .needsSignIn,
                               "\"\(prompt)\" means the user must sign in")
            }

            Harness.expect(SteamCMDOutput.failure(in: "Login Failure: Rate Limit Exceeded") == .rateLimited,
                           "a rate limit is not misreported as a wrong password")
            Harness.expect(SteamCMDOutput.failure(in: "ERROR! Failed to install app '588430' (No subscription)") == .notOwned,
                           "an unowned game is reported as such")
            Harness.expect(SteamCMDOutput.failure(in: "ERROR! Failed to install app '1' (Not enough disk space)") == .diskFull,
                           "running out of disk is reported as such")
            Harness.expect(SteamCMDOutput.failure(in: "Waiting for user info...OK") == nil,
                           "a successful sign-in step is not a failure")

            Harness.expect(SteamCMDOutput.isSignedIn("Logged in OK"), "a completed sign-in is recognised")
            Harness.expect(SteamCMDOutput.Failure.notOwned.explanation.contains("Add to Library"),
                           "the unowned-game advice tells the user what to press")
        }
    }
}

/// A real user's Steam password appeared on screen during sign-in, because
/// SteamCMD's hidden prompt never switched the terminal to hidden input.
enum SteamSignInSecurityTests {
    static func run() throws {
        Harness.suite("Steam sign-in hides typing") {
            let cmd = SteamCMD.hiddenSignInCommand(username: "niranjan_63")
            let parts = cmd.components(separatedBy: "; ")
            let echoOff = parts.firstIndex { $0.hasPrefix("stty -echo") }
            let steam = parts.firstIndex { $0.contains("steamcmd.sh") }
            Harness.expect(echoOff != nil, "typing is switched to hidden before sign-in")
            Harness.expect(echoOff != nil && steam != nil && echoOff! < steam!,
                           "and it happens before SteamCMD starts reading input")
            Harness.expect(parts.first?.hasPrefix("trap 'stty echo") == true,
                           "visible typing is restored on every exit, including Ctrl+C")
            Harness.expect(cmd.contains("+login niranjan_63 +quit"), "the account name is passed through")
            Harness.expect(!SteamCMD.hiddenSignInCommand(username: "x; rm -rf ~").contains("; rm"),
                           "an account name can't smuggle in a shell command")
            Harness.expect(cmd.contains("stty -echo 2>/dev/null || {") && cmd.contains("exit 1"),
                           "if typing can't be hidden, sign-in stops before SteamCMD asks for a password")

            // The panel that displayed a real password even with echo off.
            Harness.expect(SteamCMD.signInRefusalReason(environment: ["TERM_PROGRAM": "claude-desktop"],
                                                        inputIsTerminal: true) != nil,
                           "sign-in refuses to run in Claude's terminal panel")
            Harness.expect(SteamCMD.signInRefusalReason(environment: ["TERM_PROGRAM": "Apple_Terminal"],
                                                        inputIsTerminal: false) != nil,
                           "sign-in refuses when input isn't a real terminal")
            Harness.expect(SteamCMD.signInRefusalReason(environment: ["TERM_PROGRAM": "Apple_Terminal"],
                                                        inputIsTerminal: true) == nil,
                           "sign-in is allowed in the Terminal app")
        }
    }
}
