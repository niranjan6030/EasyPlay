import Foundation

/// The bundled knowledge base of games.
public struct GameCatalog {
    public let entries: [CatalogEntry]
    public let lastReviewed: String
    public let disclaimer: String
    public private(set) var loadError: Error?

    private struct File: Codable {
        let schemaVersion: Int
        let lastReviewed: String
        let disclaimer: String
        let entries: [CatalogEntry]
    }

    public static var bundledCatalogURL: URL? {
        if let resources = Bundle.main.resourceURL?
            .appendingPathComponent("Catalog/catalog.json"),
           FileManager.default.fileExists(atPath: resources.path) {
            return resources
        }
        return Bundle.module.url(forResource: "Catalog/catalog.json", withExtension: nil)
            ?? Bundle.module.url(forResource: "catalog", withExtension: "json")
    }

    public init(url: URL? = nil) {
        let source = url ?? Self.bundledCatalogURL
        guard let source, let data = try? Data(contentsOf: source) else {
            entries = []; lastReviewed = "unknown"; disclaimer = ""
            loadError = CocoaError(.fileNoSuchFile)
            return
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            entries = file.entries
            lastReviewed = file.lastReviewed
            disclaimer = file.disclaimer
        } catch {
            entries = []; lastReviewed = "unknown"; disclaimer = ""
            loadError = error
        }
    }

    public func entry(id: String) -> CatalogEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - Matching

    /// A candidate match and how confident we are in it.
    public struct Match {
        public let entry: CatalogEntry
        /// 0-1. Anything below `GameCatalog.confidenceThreshold` is not used.
        public let score: Double
    }

    /// Below this, EasyPlay says it doesn't know rather than guessing. Answering
    /// the wrong game's question is worse than answering none.
    public static let confidenceThreshold = 0.62

    /// A "did you mean…?" needs to be a real near-miss. Suggesting three
    /// unrelated games because the query was nonsense is noise, not help.
    public static let suggestionThreshold = 0.50

    /// Finds the entries best matching a free-text game name.
    public func match(_ text: String, limit: Int = 3) -> [Match] {
        let needle = Self.normalise(text)
        guard !needle.isEmpty else { return [] }

        return entries
            .map { entry in
                let best = entry.searchableNames
                    .map { Self.similarity(needle, Self.normalise($0)) }
                    .max() ?? 0
                return Match(entry: entry, score: best)
            }
            .filter { $0.score > 0.3 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    public func bestMatch(_ text: String) -> CatalogEntry? {
        guard let top = match(text, limit: 1).first,
              top.score >= Self.confidenceThreshold else { return nil }
        return top.entry
    }

    // MARK: - String comparison

    /// Lowercases, strips punctuation and articles, and collapses whitespace, so
    /// "Baldur's Gate 3", "baldurs gate 3" and "BALDURS  GATE III" all agree.
    public static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let stripped = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(stripped)
            .split(separator: " ")
            .map(String.init)
            .map { romanNumerals[$0] ?? $0 }
            .joined(separator: " ")
    }

    /// "Civilization VI" and "civilization 6" are the same game.
    private static let romanNumerals: [String: String] = [
        "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6",
        "vii": "7", "viii": "8", "ix": "9", "x": "10",
    ]

    /// Blends exact, prefix, containment and edit-distance similarity.
    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1.0 }

        // A short query that is a whole word of the title is a strong signal:
        // "skyrim" should find "The Elder Scrolls V: Skyrim Special Edition".
        let aTokens = Set(a.split(separator: " ").map(String.init))
        let bTokens = Set(b.split(separator: " ").map(String.init))
        if !aTokens.isEmpty, aTokens.isSubset(of: bTokens) {
            return 0.80 + 0.15 * (Double(aTokens.count) / Double(max(bTokens.count, 1)))
        }
        if b.contains(a) || a.contains(b) { return 0.78 }

        let overlap = Double(aTokens.intersection(bTokens).count)
        let union = Double(aTokens.union(bTokens).count)
        let jaccard = union > 0 ? overlap / union : 0

        return max(jaccard, editSimilarity(a, b))
    }

    /// Normalised Levenshtein similarity, for typos like "cyberpunck".
    static func editSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        let distance = Double(previous[y.count])
        return 1.0 - distance / Double(max(x.count, y.count))
    }
}
