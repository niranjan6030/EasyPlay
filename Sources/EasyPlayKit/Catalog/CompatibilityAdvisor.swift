import Foundation

/// Answers "can I run this on my Mac?" from data, never from guesswork.
///
/// This is the honest core of the feature. The advisor will happily say it does
/// not know — a wrong "yes" costs someone a purchase and a long download, and an
/// unsourced "yes" is indistinguishable from a wrong one. Every answer it gives
/// carries where the claim came from and when it was last checked.
public struct CompatibilityAdvisor {

    public struct Advice {
        public enum Verdict {
            /// There is an official macOS build — EasyPlay isn't needed.
            case playNatively
            /// Structurally impossible. Kernel anti-cheat, almost always.
            case willNotRun
            /// EasyPlay ships a preset for this game.
            case hasPreset
            /// Nothing known blocks it, but nobody has verified it.
            case noKnownBlocker
            /// Not in the catalog. EasyPlay does not guess.
            case unknown

            public var rating: CompatibilityRating {
                switch self {
                case .playNatively, .hasPreset: return .runsGreat
                case .willNotRun: return .notSupported
                case .noKnownBlocker, .unknown: return .untested
                }
            }
        }

        /// Something the user can do next.
        public struct Action: Identifiable {
            public enum Kind: Equatable {
                case openURL(URL)
                case installPreset(recipeID: String)
            }
            public let title: String
            public let kind: Kind
            public var id: String { title }
        }

        public let verdict: Verdict
        public let headline: String
        public let explanation: String
        /// Where the claim comes from. Never empty for a definite answer.
        public let source: String?
        public let entry: CatalogEntry?
        public let notes: [String]
        public let actions: [Action]
        /// Other games the question might have meant.
        public let alternatives: [CatalogEntry]
    }

    public typealias Action = Advice.Action

    private let catalog: GameCatalog
    private let recipes: RecipeLibrary

    public init(catalog: GameCatalog = GameCatalog(), recipes: RecipeLibrary = RecipeLibrary()) {
        self.catalog = catalog
        self.recipes = recipes
    }

    /// Answers a free-text question.
    public func answer(to question: String) -> Advice {
        let name = Self.extractGameName(from: question)

        guard !name.isEmpty else {
            return Advice(
                verdict: .unknown,
                headline: "Which game?",
                explanation: "Tell me a game name and I'll say what EasyPlay knows about it — for example \"can I run Elden Ring?\".",
                source: nil, entry: nil, notes: [], actions: [], alternatives: []
            )
        }

        let matches = catalog.match(name, limit: 3)
        guard let best = matches.first, best.score >= GameCatalog.confidenceThreshold else {
            let plausible = matches.filter { $0.score >= GameCatalog.suggestionThreshold }
            return unknownGame(name, near: plausible.map(\.entry))
        }

        return advice(for: best.entry)
    }

    /// Builds advice for a catalog entry. Rules are applied in order of how
    /// certain they are, so the strongest fact always wins.
    public func advice(for entry: CatalogEntry) -> Advice {
        var actions: [Action] = []
        if let url = entry.store?.storeURL {
            actions.append(Action(title: "Open on \(entry.store!.kind.displayName)", kind: .openURL(url)))
        }

        // 1. A native Mac build beats everything EasyPlay can offer.
        if entry.macNative {
            return Advice(
                verdict: .playNatively,
                headline: "\(entry.title) has a Mac version",
                explanation: "You don't need EasyPlay for this one. \(entry.publisher.map { "\($0) ships" } ?? "There is") an official macOS build, which will run better than anything Wine can do — buy the Mac version.",
                source: entry.source, entry: entry, notes: entry.notes,
                actions: actions, alternatives: []
            )
        }

        // 2. Kernel anti-cheat is structural. No preset will ever fix it — but
        //    only when it governs the whole game.
        if entry.isBlockedByAntiCheat, let antiCheat = entry.antiCheat {
            return Advice(
                verdict: .willNotRun,
                headline: "\(entry.title) won't run on a Mac",
                explanation: "\(antiCheat.explanation) This will not work under EasyPlay, CrossOver, or any other Wine-based tool, and it isn't something a future update will fix. Trying to work around it can also get your account banned.",
                source: entry.source, entry: entry, notes: entry.notes,
                actions: actions, alternatives: []
            )
        }

        // 3. A shipped preset means the configuration work is already done.
        if let presetID = entry.presetID, let recipe = try? recipes.recipe(id: presetID) {
            actions.insert(Action(title: "Use the \(recipe.title) preset", kind: .installPreset(recipeID: presetID)), at: 0)
            return Advice(
                verdict: .hasPreset,
                headline: "\(entry.title) — EasyPlay has a preset for this",
                explanation: "Rated \(recipe.compatibility.rating.displayName.lowercased()). EasyPlay knows the Windows version, graphics translator and DLL settings this game needs, and will apply them when you install it.",
                source: recipe.compatibility.source ?? entry.source,
                entry: entry, notes: recipe.compatibility.notes,
                actions: actions, alternatives: []
            )
        }

        // 4. Known game, nothing blocking it, but nobody has actually run it.
        actions.append(contentsOf: Self.researchActions(for: entry))
        return Advice(
            verdict: .noKnownBlocker,
            headline: "\(entry.title) — probably, but it's unverified",
            explanation: "Nothing EasyPlay knows about blocks this game\(Self.blockerClause(for: entry)). But nobody has verified it here, so this is not a promise. Check a compatibility database before you buy.",
            source: entry.source, entry: entry, notes: entry.notes,
            actions: actions, alternatives: []
        )
    }

    /// The middle of the "no known blocker" sentence, which has to read properly
    /// whether or not we know the anti-cheat or graphics API.
    private static func blockerClause(for entry: CatalogEntry) -> String {
        if let antiCheat = entry.antiCheat, antiCheat.isKernelLevel,
           entry.antiCheatScope == .onlineOnly {
            return ". Its \(antiCheat.displayName) anti-cheat only covers the online mode, so single-player should work and multiplayer will not"
        }
        if let antiCheat = entry.antiCheat {
            return ". It uses \(antiCheat.displayName), which isn't kernel-level and doesn't block Wine by itself"
        }
        if !entry.graphicsAPI.isEmpty {
            return " — no anti-cheat, and \(entry.graphicsAPI.joined(separator: " / "))"
        }
        return " — no known anti-cheat"
    }

    private func unknownGame(_ name: String, near alternatives: [CatalogEntry]) -> Advice {
        Advice(
            verdict: .unknown,
            headline: "I don't have data on \(name.capitalisedWords)",
            explanation: "EasyPlay only answers from what it actually knows, and this game isn't in its catalogue — so rather than guess, here's where to look it up. The two databases below are the ones EasyPlay's own ratings are drawn from.",
            source: nil, entry: nil, notes: [],
            actions: Self.researchActions(forQuery: name),
            alternatives: alternatives
        )
    }

    /// Links out to the public databases, so an "I don't know" is still useful.
    private static func researchActions(for entry: CatalogEntry) -> [Action] {
        researchActions(forQuery: entry.title)
    }

    private static func researchActions(forQuery query: String) -> [Action] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var actions: [Action] = []
        if let url = URL(string: "https://www.codeweavers.com/compatibility?browse=&app_desc=&company=&rating=&platform=&date_start=&date_end=&name=\(encoded)") {
            actions.append(Action(title: "Check CrossOver database", kind: .openURL(url)))
        }
        if let url = URL(string: "https://www.protondb.com/search?q=\(encoded)") {
            actions.append(Action(title: "Check ProtonDB", kind: .openURL(url)))
        }
        return actions
    }

    // MARK: - Question parsing

    /// Pulls a probable game name out of a natural-language question.
    ///
    /// Deliberately simple: strip the phrasing people wrap around a title and
    /// keep what's left. It does not need to understand the sentence, only to
    /// find the noun — and when it gets that wrong, the confidence threshold in
    /// `GameCatalog` catches it and the advisor says it doesn't know.
    public static func extractGameName(from question: String) -> String {
        var text = question.lowercased()

        let phrases = [
            "can i run", "can i play", "will i be able to run", "am i able to run",
            "does it run", "will it run", "does", "will", "can",
            "is it possible to run", "is it possible to play", "how about", "what about",
            "on my mac", "on my macbook", "on mac", "on macos", "on apple silicon",
            "on my m1", "on my m2", "on my m3", "on my m4", "on this mac",
            "run on", "work on", "play on", "supported", "compatible with",
            "i want to play", "i want to run", "tell me about", "any info on",
            "run", "play", "work", "please", "thanks", "hey", "hi", "hello", "help",
        ]
        for phrase in phrases {
            text = text.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b",
                                             with: " ", options: .regularExpression)
        }

        // Trailing filler and punctuation.
        text = text.replacingOccurrences(of: "[?!.,]", with: " ", options: .regularExpression)
        let stopWords: Set<String> = ["i", "it", "the", "a", "an", "my", "me", "to", "on", "in", "of", "is", "are", "with", "for", "and", "or", "do", "did", "you", "know", "about", "if", "whether", "game"]
        let words = text.split(separator: " ").map(String.init).filter { !stopWords.contains($0) && !$0.isEmpty }

        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

extension String {
    var capitalisedWords: String {
        split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
