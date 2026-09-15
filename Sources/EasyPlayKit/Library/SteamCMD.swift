import Foundation

/// Valve's official command-line Steam client, running natively on macOS.
///
/// EasyPlay originally installed the Windows Steam client into each bottle. On
/// every free Wine build available for macOS that client can no longer sign in:
/// its interface talks to the client over a local WebSocket whose handshake
/// fails with Windows socket error 10045, leaving a black window. SteamCMD has
/// no browser interface and needs no Wine at all, and it can fetch the Windows
/// build of a game onto a Mac — which is all EasyPlay needs from Steam.
///
/// Credentials never pass through EasyPlay. Signing in happens in a Terminal
/// window running SteamCMD itself, where the user types their own password and
/// Steam Guard code; SteamCMD caches the session and later downloads reuse it.
public struct SteamCMD {
    public typealias ProgressHandler = (String) -> Void

    public enum SteamCMDError: LocalizedError {
        case notInstalled
        case failed(SteamCMDOutput.Failure)
        case stalled(minutes: Int, lastPercent: Double?)
        case exitedWithoutSuccess(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "SteamCMD isn't installed yet."
            case .failed(let failure):
                return failure.explanation
            case .stalled(let minutes, let percent):
                let at = percent.map { " at \(Int($0))%" } ?? ""
                return "The download made no progress for \(minutes) minutes\(at), so EasyPlay stopped it. Check your internet connection and try again — Steam resumes where it left off."
            case .exitedWithoutSuccess(let tail):
                return "Steam stopped before finishing. Last message: \(tail)"
            }
        }

        public var failure: SteamCMDOutput.Failure? {
            if case .failed(let f) = self { return f }
            return nil
        }
    }

    /// Valve's macOS SteamCMD. Downloaded from Valve and nowhere else.
    public static let downloadURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    public static var directory: URL {
        AppPaths.runtimesDirectory.appendingPathComponent("steamcmd", isDirectory: true)
    }
    public static var script: URL { directory.appendingPathComponent("steamcmd.sh") }

    private let runner: ProcessRunner
    private let fileManager: FileManager

    public init(runner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public var isInstalled: Bool {
        fileManager.isExecutableFile(atPath: Self.script.path)
            && fileManager.fileExists(atPath: Self.directory.appendingPathComponent("steamcmd").path)
    }

    /// Downloads SteamCMD and lets it update itself once.
    public func install(onProgress: ProgressHandler? = nil) throws {
        if isInstalled { return }
        try AppPaths.ensureDirectories()
        try fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        onProgress?("Downloading SteamCMD from Valve…")
        let archive = Self.directory.appendingPathComponent("steamcmd_osx.tar.gz")
        try runner.runChecked("/usr/bin/curl", ["-fsSL", "--retry", "3", "-o", archive.path,
                                                Self.downloadURL.absoluteString], timeout: 300)
        try runner.runChecked("/usr/bin/tar", ["-xzf", archive.path, "-C", Self.directory.path], timeout: 120)
        try? fileManager.removeItem(at: archive)

        onProgress?("Updating SteamCMD (first run only)…")
        _ = try runner.run(Self.script.path, ["+quit"], timeout: 600)
        guard isInstalled else { throw SteamCMDError.notInstalled }
    }

    // MARK: - Signing in

    /// Checks whether SteamCMD holds a usable cached login for this account,
    /// without ever prompting: standard input is closed, so a password prompt
    /// ends the check instead of waiting for input.
    public func isSignedIn(username: String) -> Bool {
        guard isInstalled, !username.isEmpty else { return false }
        var signedIn = false
        let process = Process()
        process.executableURL = Self.script
        process.arguments = ["+login", username, "+quit"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return false }

        let deadline = Date().addingTimeInterval(90)
        var buffer = ""
        let handle = pipe.fileHandleForReading
        while process.isRunning, Date() < deadline {
            let data = handle.availableData
            if data.isEmpty { Thread.sleep(forTimeInterval: 0.2); continue }
            buffer += String(decoding: data, as: UTF8.self)
            if buffer.split(whereSeparator: \.isNewline).contains(where: { SteamCMDOutput.isSignedIn(String($0)) }) {
                signedIn = true
            }
            if buffer.split(whereSeparator: \.isNewline).contains(where: { SteamCMDOutput.failure(in: String($0)) == .needsSignIn })
                || buffer.lowercased().contains("password:") {
                break
            }
        }
        if process.isRunning { process.terminate() }
        return signedIn
    }

    /// The shell command that runs SteamCMD's sign-in with typing hidden.
    ///
    /// SteamCMD redirects its stderr to a log file, and its `password:` prompt
    /// goes with it — so the terminal never shows a prompt and never switches
    /// to hidden input, and a password typed at the blank cursor is printed on
    /// screen in plain text. That happened to a real user. So echo is switched
    /// off before SteamCMD starts, restored on every exit path including
    /// Ctrl+C, and EasyPlay prints the instructions SteamCMD's hidden prompt
    /// would have shown. EasyPlay still never reads the input: it goes from the
    /// keyboard to SteamCMD through the terminal.
    public static func hiddenSignInCommand(username: String) -> String {
        let safeName = username.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
        let script = Self.script.path.replacingOccurrences(of: "'", with: "'\\''")
        return [
            "trap 'stty echo 2>/dev/null' EXIT INT TERM",
            "stty -echo",
            "echo 'Typing is hidden for this sign-in, so nothing will appear as you type.'",
            "echo 'When SteamCMD finishes starting (after \"Cached credentials not found\"):'",
            "echo '  1. type your Steam password and press Enter'",
            "echo '  2. type your Steam Guard code and press Enter, or approve on your phone'",
            "echo",
            "'\(script)' +login \(safeName) +quit",
            "stty echo",
        ].joined(separator: "; ")
    }

    /// Opens Terminal running SteamCMD's own sign-in for this account.
    ///
    /// The user types their password and Steam Guard code into SteamCMD
    /// directly. EasyPlay only ever supplies the account name.
    public func openSignInWindow(username: String) throws {
        guard isInstalled else { throw SteamCMDError.notInstalled }
        let command = "clear; /bin/bash -c \"" + Self.hiddenSignInCommand(username: username)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\"; "
            + "echo; echo 'You can close this window and return to EasyPlay.'"
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        try runner.runChecked("/usr/bin/osascript", ["-e", script], timeout: 30)
    }

    // MARK: - Downloading

    /// Downloads the Windows build of a game into `directory`.
    ///
    /// Watched rather than merely waited on: if Steam reports no progress for
    /// `stallMinutes`, the download is stopped and the user is told, instead of
    /// the app sitting silently for hours. The Mac is kept awake while it runs.
    public func download(appID: String,
                         into directory: URL,
                         username: String,
                         stallMinutes: Int = 10,
                         onProgress: ProgressHandler? = nil,
                         onPercent: ((Double) -> Void)? = nil,
                         shouldContinue: @escaping () -> Bool = { true }) throws {
        guard isInstalled else { throw SteamCMDError.notInstalled }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = Self.script
        process.arguments = [
            "+@sSteamCmdForcePlatformType", "windows",
            "+force_install_dir", directory.path,
            "+login", username,
            "+app_update", appID, "validate",
            "+quit",
        ]
        // Never allow a password prompt to wait for input that isn't coming.
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let keepAwake = KeepAwake.whileRunning(pid: process.processIdentifier, runner: runner)
        defer { keepAwake?.terminate() }

        var lastChange = Date()
        var lastPercent: Double?
        var lastBytes: Int64 = -1
        var succeeded = false
        var failure: SteamCMDOutput.Failure?
        var tail = ""
        var partial = ""
        let handle = pipe.fileHandleForReading

        func consume(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            tail = trimmed
            if let p = SteamCMDOutput.progress(in: trimmed) {
                if p.bytesDone != lastBytes {
                    lastBytes = p.bytesDone
                    lastChange = Date()
                }
                if p.bytesTotal > 0 {
                    lastPercent = p.percent
                    onPercent?(p.percent / 100)
                    let done = Double(p.bytesDone) / 1_048_576
                    let total = Double(p.bytesTotal) / 1_048_576
                    onProgress?(String(format: "Downloading — %.0f%% (%.0f of %.0f MB)", p.percent, done, total))
                }
            } else if SteamCMDOutput.isSignedIn(trimmed) {
                lastChange = Date()
                onProgress?("Signed in to Steam.")
            } else if SteamCMDOutput.isSuccess(trimmed, appID: appID) {
                succeeded = true
            } else if let f = SteamCMDOutput.failure(in: trimmed), failure == nil {
                failure = f
            } else if trimmed.hasPrefix("[") || trimmed.contains("Verifying") {
                // SteamCMD's own update and verification phases are progress too.
                lastChange = Date()
            }
        }

        while process.isRunning {
            let data = handle.availableData
            if !data.isEmpty {
                partial += String(decoding: data, as: UTF8.self)
                var lines = partial.components(separatedBy: CharacterSet.newlines)
                partial = lines.removeLast()
                lines.forEach(consume)
            } else {
                Thread.sleep(forTimeInterval: 0.25)
            }

            if failure != nil || !shouldContinue() {
                process.terminate()
                break
            }
            if Date().timeIntervalSince(lastChange) > Double(stallMinutes * 60) {
                process.terminate()
                throw SteamCMDError.stalled(minutes: stallMinutes, lastPercent: lastPercent)
            }
        }
        process.waitUntilExit()
        let rest = handle.readDataToEndOfFile()
        partial += String(decoding: rest, as: UTF8.self)
        partial.components(separatedBy: CharacterSet.newlines).forEach(consume)

        if let failure { throw SteamCMDError.failed(failure) }
        guard succeeded else { throw SteamCMDError.exitedWithoutSuccess(tail) }
    }
}

/// Holds a macOS power assertion for as long as another process runs.
///
/// A download that takes an hour must not be cut short by the Mac going to
/// sleep, and EasyPlay used to tell users to keep the Mac awake without doing
/// anything about it itself.
public enum KeepAwake {
    public static func whileRunning(pid: Int32, runner: ProcessRunner = ProcessRunner()) -> Process? {
        // -i: prevent idle sleep. -w: release the assertion when `pid` exits.
        try? runner.launch("/usr/bin/caffeinate", ["-i", "-w", "\(pid)"])
    }
}
