import Foundation

/// Turns Wine's output into something a player can act on.
///
/// This is the feature that decides whether EasyPlay is worth using. Wine
/// already tells you exactly what went wrong — in a format written for people
/// who work on Wine. The classifier reads the same text and answers the only two
/// questions a player has: what broke, and what do I do now.
public struct LogClassifier {

    private let recipe: Recipe?

    public init(recipe: Recipe? = nil) {
        self.recipe = recipe
    }

    /// Diagnoses a Wine log, most specific match first.
    ///
    /// A recipe's own patterns are checked before the global ones, because a
    /// per-game explanation is always better than a generic one.
    public func classify(log: String, exitCode: Int32? = nil) -> [Diagnosis] {
        var diagnoses: [Diagnosis] = []
        var seenIDs = Set<String>()

        for issue in recipe?.knownIssues ?? [] {
            guard let evidence = firstMatch(of: issue.match, in: log) else { continue }
            let id = "recipe:\(issue.match)"
            guard seenIDs.insert(id).inserted else { continue }
            diagnoses.append(Diagnosis(
                id: id,
                title: issue.title,
                explanation: issue.fix,
                remedy: issue.action.flatMap(Diagnosis.Remedy.init(action:)),
                evidence: evidence
            ))
        }

        for pattern in GlobalKnownIssues.all {
            guard let evidence = firstMatch(of: pattern.regex, in: log) else { continue }
            guard seenIDs.insert(pattern.id).inserted else { continue }
            diagnoses.append(Diagnosis(
                id: pattern.id,
                title: pattern.title,
                explanation: pattern.explanation,
                remedy: pattern.action.flatMap(Diagnosis.Remedy.init(action:)),
                evidence: evidence
            ))
        }

        // A non-zero exit we can't explain is still worth saying out loud, rather
        // than leaving the user staring at a window that closed itself.
        if diagnoses.isEmpty, let exitCode, exitCode != 0 {
            diagnoses.append(Diagnosis(
                id: "unknown-failure",
                title: "The game closed unexpectedly",
                explanation: "EasyPlay doesn't recognise this failure. The full log is saved if you want to look, and it's worth checking whether a newer preset exists for this game.",
                remedy: nil,
                evidence: Self.interestingLines(from: log).joined(separator: "\n")
            ))
        }

        return diagnoses
    }

    private func firstMatch(of pattern: String, in log: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(log.startIndex..., in: log)
        guard let match = regex.firstMatch(in: log, options: [], range: range),
              let matchRange = Range(match.range, in: log) else { return nil }

        // Return the whole log line, not just the matched fragment — context is
        // what makes the "show details" disclosure useful.
        let lineStart = log[..<matchRange.lowerBound].lastIndex(of: "\n").map { log.index(after: $0) } ?? log.startIndex
        let lineEnd = log[matchRange.upperBound...].firstIndex(of: "\n") ?? log.endIndex
        return String(log[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
    }

    /// Pulls the lines most likely to matter out of a long log.
    public static func interestingLines(from log: String, limit: Int = 8) -> [String] {
        log.split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("err:") || $0.lowercased().contains("error") || $0.contains("Unhandled exception") }
            .suffix(limit)
    }
}
