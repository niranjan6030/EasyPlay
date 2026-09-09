import Foundation

/// Outcome of a single child-process invocation.
public struct CommandResult {
    public let executable: String
    public let arguments: [String]
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 }

    /// stdout and stderr interleaved is impossible after the fact, so we simply
    /// concatenate. Good enough for the log classifier, which greps for patterns.
    public var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public var commandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public enum ProcessError: LocalizedError {
    case executableNotFound(String)
    case launchFailed(command: String, underlying: Error)
    case timedOut(command: String, seconds: TimeInterval)
    case nonZeroExit(CommandResult)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "Couldn't find '\(name)' on this Mac."
        case .launchFailed(let command, let underlying):
            return "Couldn't start '\(command)': \(underlying.localizedDescription)"
        case .timedOut(let command, let seconds):
            return "'\(command)' didn't finish within \(Int(seconds))s and was stopped."
        case .nonZeroExit(let result):
            return "'\(result.commandLine)' exited with code \(result.exitCode)."
        }
    }
}

/// A thin, dependency-free wrapper around `Process`.
///
/// Every external tool EasyPlay drives — `brew`, `wine`, `wineserver`, `winetricks`
/// — is invoked through here, so process handling, environment injection and log
/// capture are written once and tested once.
public struct ProcessRunner {

    /// Streams a line of output as it is produced. Used by long-running installs
    /// so the UI can show progress instead of freezing.
    public typealias OutputHandler = (String) -> Void

    public init() {}

    /// Resolves an executable name against `PATH`, plus the Homebrew prefixes,
    /// which are commonly missing from the environment a GUI app inherits.
    public static func locate(_ name: String) -> URL? {
        if name.contains("/") {
            let url = URL(fileURLWithPath: name)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        var searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        // A double-clicked .app inherits a minimal PATH that omits Homebrew.
        searchPaths.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])

        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    public func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String] = [:],
        replaceEnvironment: Bool = false,
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        onOutput: OutputHandler? = nil
    ) throws -> CommandResult {
        guard let executableURL = Self.locate(executable) else {
            throw ProcessError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        var mergedEnvironment = replaceEnvironment ? [:] : ProcessInfo.processInfo.environment
        mergedEnvironment.merge(environment) { _, new in new }
        process.environment = mergedEnvironment

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector(onOutput: onOutput)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.appendStandardOutput(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.appendStandardError(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(command: executable, underlying: error)
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                // Give it a beat to die politely before we stop waiting on it.
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw ProcessError.timedOut(command: executable, seconds: timeout)
            }
        }

        process.waitUntilExit()

        // Drain anything the handlers hadn't picked up before the process exited.
        collector.appendStandardOutput(outPipe.fileHandleForReading.readDataToEndOfFile())
        collector.appendStandardError(errPipe.fileHandleForReading.readDataToEndOfFile())
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        return CommandResult(
            executable: executableURL.path,
            arguments: arguments,
            exitCode: process.terminationStatus,
            standardOutput: collector.standardOutput,
            standardError: collector.standardError
        )
    }

    /// Starts a process and returns immediately.
    ///
    /// Needed for anything long-running that EasyPlay has to work alongside
    /// rather than wait for — the Steam client is the case that forced it: the
    /// user signs in and downloads while EasyPlay watches the manifest.
    public func launch(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil
    ) throws -> Process {
        guard let executableURL = Self.locate(executable) else {
            throw ProcessError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        var merged = ProcessInfo.processInfo.environment
        merged.merge(environment) { _, new in new }
        process.environment = merged
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        // Output is discarded deliberately: a GUI app left running for an hour
        // would otherwise fill a pipe nobody is draining and block.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(command: executable, underlying: error)
        }
        return process
    }

    /// Same as `run`, but throws when the command reports failure. Use where a
    /// non-zero exit means the operation genuinely cannot continue.
    @discardableResult
    public func runChecked(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        onOutput: OutputHandler? = nil
    ) throws -> CommandResult {
        let result = try run(
            executable, arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            onOutput: onOutput
        )
        guard result.succeeded else { throw ProcessError.nonZeroExit(result) }
        return result
    }
}

/// Accumulates pipe output from the reader queues behind a lock.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var lineBuffer = ""
    private let onOutput: ProcessRunner.OutputHandler?

    init(onOutput: ProcessRunner.OutputHandler?) {
        self.onOutput = onOutput
    }

    func appendStandardOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        out.append(data)
        lock.unlock()
        emitLines(from: data)
    }

    func appendStandardError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        err.append(data)
        lock.unlock()
        emitLines(from: data)
    }

    var standardOutput: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var standardError: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }

    private func emitLines(from data: Data) {
        guard let onOutput else { return }
        lock.lock()
        lineBuffer += String(decoding: data, as: UTF8.self)
        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast()  // trailing partial line
        lock.unlock()
        lines.forEach(onOutput)
    }
}
